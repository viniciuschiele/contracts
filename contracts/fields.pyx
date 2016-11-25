"""
Provides a set of classes to serialize Python objects.
"""

cimport cython
import ciso8601
import uuid

from cpython.datetime cimport datetime, date
from . import timezone
from . cimport abc
from . cimport timezone
from . cimport validators
from .exceptions cimport ValidationError
from .utils cimport missing


cdef class Field(abc.Field):
    default_error_messages = {
        'null': 'This field may not be null.',
        'required': 'This field is required.',
        'validator_failed': 'Invalid value.'
    }

    def __init__(self, bint dump_only=False, bint load_only=False, required=None, object default=missing, allow_none=None,
                 str dump_to=None, str load_from=None, dict error_messages=None, list validators=None):
        self.dump_only = dump_only
        self.load_only = load_only
        self.default_value = default
        self.allow_none = allow_none
        self.dump_to = dump_to
        self.load_from = load_from
        self.validators = validators or []

        # If `required` is unset, then use `True` unless a default is provided.
        if required is None:
            self.required = default is missing
        else:
            self.required = required

        if allow_none is None:
            self.allow_none = default is None
        else:
            self.allow_none = allow_none

        self.name = None
        self.parent = None
        self._decorator_validators = []

        self._prepare_error_messages(error_messages)

    cpdef bind(self, str name, abc.Contract parent):
        self.name = name
        self.parent = parent

        if not self.dump_to:
            self.dump_to = name

        if not self.load_from:
            self.load_from = name

        for validator in self._decorator_validators:
            self.validators.append(getattr(parent, validator))

    cpdef object dump(self, object value):
        if value is missing:
            return missing

        if value is None:
            return None

        return self._dump(value)

    cpdef object load(self, object value):
        if value is None:
            if self.allow_none:
                return None

            self._fail('null')

        if value is missing:
            if self.required:
                self._fail('required')

            return self._get_default()

        validated_value = self._load(value)
        self._validate(validated_value)
        return validated_value

    cpdef validator(self, func):
        self._decorator_validators.append(func.__name__)
        return func

    cdef _prepare_error_messages(self, dict error_messages):
        cdef dict messages = {}

        for cls in reversed(self.__class__.__mro__):
            messages.update(getattr(cls, 'default_error_messages', {}))

        if error_messages:
            messages.update(error_messages)

        self.error_messages = messages

    cpdef _get_default(self):
        if self.default_value is missing:
            return missing

        if callable(self.default_value):
            return self.default_value()

        return self.default_value

    cpdef object _dump(self, object value):
        return value

    cpdef object _load(self, object value):
        return value

    def _fail(self, key, **kwargs):
        try:
            message = self.error_messages[key]
            if isinstance(message, str):
                message = message.format(**kwargs)

            raise ValidationError(message)
        except KeyError:
            raise AssertionError(
                'ValidationError raised by `{class_name}`, but error key `{key}` does '
                'not exist in the `error_messages` dictionary.'.format(
                    class_name=self.__class__.__name__, key=key))

    cpdef _validate(self, object value):
        cdef list errors = None

        for validator in self.validators:
            try:
                if validator(value) is False:
                    self._fail('validator_failed')
            except ValidationError as e:
                if errors is None:
                    errors = [e]
                else:
                    errors.append(e)

        if errors:
            raise ValidationError(errors)


cdef class Boolean(Field):
    default_error_messages = {
        'invalid': '"{value}" is not a valid boolean.'
    }

    default_options = {
        'true_values': {'t', 'T', 'true', 'True', 'TRUE', '1', 1, True},
        'false_values': {'f', 'F', 'false', 'False', 'FALSE', '0', 0, 0.0, False}
    }

    def __init__(self, **kwargs):
        super(Boolean, self).__init__(**kwargs)

        self._true_values = self.default_options.get('true_values')
        self._false_values = self.default_options.get('false_values')

    cpdef object _load(self, object value):
        if isinstance(value, bool):
            return value

        try:
            if value in self._true_values:
                return True

            if value in self._false_values:
                return False
        except TypeError:
            pass

        self._fail('invalid', value=value)

    cpdef object _dump(self, object value):
        if isinstance(value, bool):
            return value

        if value in self._true_values:
            return True

        if value in self._false_values:
            return False

        return bool(value)


cdef class Date(Field):
    default_error_messages = {
        'invalid': 'Date has wrong format.'
    }

    cpdef object _load(self, object value):
        if isinstance(value, datetime):
            return value.date()

        if isinstance(value, date):
            return value

        try:
            parsed = ciso8601.parse_datetime_unaware(value)
            if parsed is not None:
                return parsed.date()
        except (ValueError, TypeError):
            pass

        self._fail('invalid')

    cpdef object _dump(self, object value):
        if isinstance(value, datetime):
            return value.date().isoformat()

        return value.isoformat()


cdef class DateTime(Field):
    default_error_messages = {
        'invalid': 'Datetime has wrong format.',
        'date': 'Expected a datetime but got a date.',
    }

    default_options = {
        'default_timezone': None
    }

    def __init__(self, default_timezone=None, **kwargs):
        super(DateTime, self).__init__(**kwargs)

        if default_timezone is None:
            self.default_timezone = self.default_options.get('default_timezone')
        else:
            self.default_timezone = default_timezone

    cpdef object _load(self, object value):
        if isinstance(value, datetime):
            return self._enforce_timezone(value)

        if isinstance(value, date):
            self._fail('date')

        try:

            parsed = ciso8601.parse_datetime(value)
            if parsed is not None:
                return self._enforce_timezone(parsed)
        except (ValueError, TypeError):
            pass

        self._fail('invalid')

    cpdef object _dump(self, object value):
        return value.isoformat()

    cpdef _enforce_timezone(self, datetime value):
        if self.default_timezone is not None and not timezone.is_aware(value):
            return timezone.make_aware(value, self.default_timezone)

        elif self.default_timezone is None and timezone.is_aware(value):
            return timezone.make_naive(value, timezone.utc)

        return value


cdef class Float(Field):
    default_error_messages = {
        'invalid': 'A valid number is required.',
        'max_value': 'Ensure this value is less than or equal to {max_value}.',
        'min_value': 'Ensure this value is greater than or equal to {min_value}.',
    }

    def __init__(self, min_value=None, max_value=None, **kwargs):
        super().__init__(**kwargs)
        self.min_value = min_value
        self.max_value = max_value

        if self.min_value is not None or self.max_value is not None:
            self.validators.append(validators.Range(min_value, max_value, self.error_messages))

    cpdef object _load(self, object value):
        if isinstance(value, float):
            return value

        try:
            return float(value)
        except (TypeError, ValueError):
            self._fail('invalid')

    cpdef object _dump(self, object value):
        if isinstance(value, float):
            return value

        return float(value)


cdef class Function(Field):
    def __init__(self, object dump_func=None, object load_func=None, **kwargs):
        super(Function, self).__init__(**kwargs)

        self.dump_func = dump_func
        self.load_func = load_func

    cpdef object _dump(self, object value):
        if not self.dump_func:
            return missing

        return self.dump_func(value)

    cpdef object _load(self, object value):
        if not self.load_func:
            return missing

        return self.load_func(value)


cdef class Integer(Field):
    default_error_messages = {
        'invalid': 'A valid integer is required.',
        'max_value': 'Must be at most {max_value}.',
        'min_value': 'Must be at least {min_value}.'
    }

    def __init__(self, min_value=None, max_value=None, **kwargs):
        super().__init__(**kwargs)
        self.min_value = min_value
        self.max_value = max_value

        if self.min_value is not None or self.max_value is not None:
            self.validators.append(validators.Range(min_value, max_value, self.error_messages))

    cpdef object _load(self, object value):
        if isinstance(value, int):
            return value

        try:
            return int(value)
        except (ValueError, TypeError):
            self._fail('invalid')

    cpdef object _dump(self, object value):
        if isinstance(value, int):
            return value

        return int(value)


cdef class List(Field):
    default_error_messages = {
        'invalid': 'Not a valid list.',
        'empty': 'This list may not be empty.'
    }

    def __init__(self, abc.Field child, bint allow_empty=True, *args, **kwargs):
        super().__init__(*args, **kwargs)

        self.child = child
        self.allow_empty = allow_empty

    cpdef object _load(self, object value):
        """
        List of dicts of native values <- List of dicts of primitive datatypes.
        """
        if not isinstance(value, (tuple, list, set)):
            self._fail('invalid')

        if not self.allow_empty and len(value) == 0:
            self._fail('empty')

        cdef list result = []
        cdef dict errors = None

        for idx, item in enumerate(value):
            try:
                result.append(self.child.load(item))
            except ValidationError as e:
                if errors is None:
                    errors = {idx: e}
                else:
                    errors.update({idx: e})

        if errors:
            raise ValidationError(errors)

        return result

    cpdef object _dump(self, object value):
        """
        List of object instances -> List of dicts of primitive datatypes.
        """
        return [self.child.dump(item) for item in value]


cdef class Method(Field):
    def __init__(self, str dump_method_name=None, str load_method_name=None, **kwargs):
        super(Method, self).__init__(**kwargs)

        self.dump_method_name = dump_method_name
        self.load_method_name = load_method_name

        self._dump_method = None
        self._load_method = None

    cpdef bind(self, str name, abc.Contract parent):
        super(Method, self).bind(name, parent)

        if self.dump_method_name:
            dump_method = getattr(self.parent, self.dump_method_name, None)
            if not callable(dump_method):
                raise ValueError('Object {0!r} is not callable.'.format(dump_method))
            self._dump_method = dump_method

        if self.load_method_name:
            load_method = getattr(self.parent, self.load_method_name, None)
            if not callable(load_method):
                raise ValueError('Object {0!r} is not callable.'.format(load_method))
            self._load_method = load_method

    cpdef object _dump(self, object value):
        if not self._dump_method:
            return missing

        return self._dump_method(value)

    cpdef object _load(self, object value):
        if not self._load_method:
            return missing

        return self._load_method(value)


cdef class Nested(Field):
    def __init__(self, nested, bint many=False, set only=None, set exclude=None, **kwargs):
        super(Nested, self).__init__(**kwargs)
        self.nested = nested
        self.many = many
        self.only = only
        self.exclude = exclude

        self._instance = None

    cpdef bind(self, str name, abc.Contract parent):
        super(Nested, self).bind(name, parent)

        self._instance = self.nested(many=self.many, only=self.only, exclude=self.exclude)

    cpdef object _load(self, object value):
        return self._instance.load(value)

    cpdef object _dump(self, object value):
        return self._instance.dump(value)


cdef class String(Field):
    default_error_messages = {
        'blank': 'This field may not be blank.',
        'max_length': 'Longer than maximum length {max_length}.',
        'min_length': 'Shorter than minimum length {min_length}.'
    }

    default_options = {
        'allow_blank': False,
        'trim_whitespace': False
    }

    def __init__(self, allow_blank=None, trim_whitespace=None, min_length=None, max_length=None, **kwargs):
        super().__init__(**kwargs)

        if allow_blank is None:
            self.allow_blank = self.default_options.get('allow_blank')
        else:
            self.allow_blank = allow_blank

        if trim_whitespace is None:
            self.trim_whitespace = self.default_options.get('trim_whitespace')
        else:
            self.trim_whitespace = trim_whitespace

        self.min_length = min_length
        self.max_length = max_length

        if self.min_length is not None or self.max_length is not None:
            self.validators.append(
                validators.Length(self.min_length, self.max_length, error_messages=self.error_messages))

    cpdef object _load(self, object value):
        if not isinstance(value, str):
            value = str(value)

        if self.trim_whitespace:
            value = value.strip()

        if not self.allow_blank and value == '':
            if self.allow_none:
                return None
            self._fail('blank')

        return value

    cpdef object _dump(self, object value):
        if isinstance(value, str):
            return value
        return str(value)


cdef class UUID(Field):
    default_error_messages = {
        'invalid': '"{value}" is not a valid UUID.',
    }

    default_options = {
        'dump_format': 'hex_verbose'
    }

    valid_formats = ('hex_verbose', 'hex', 'int')

    def __init__(self, str dump_format=None, **kwargs):
        super().__init__(**kwargs)

        if dump_format is None:
            dump_format = self.default_options.get('dump_format')

        if dump_format not in self.valid_formats:
           raise ValueError(
                'Invalid format for uuid representation. '
                'Must be one of "{0}"'.format('", "'.join(self.valid_formats))
            )

        self.dump_format = dump_format

    cpdef object _load(self, object value):
        if isinstance(value, uuid.UUID):
            return value

        try:
            return uuid.UUID(hex=value)
        except (AttributeError, ValueError):
            self._fail('invalid', value=value)

    @cython.boundscheck(False)
    cpdef object _dump(self, object value):
        cdef str hex
        cdef str dump_format = self.dump_format

        if dump_format == 'hex_verbose':
            hex = '%032x' % value.int
            return hex[:8] + '-' + hex[8:12] + '-' + hex[12:16] + '-' + hex[16:20] + '-' + hex[20:]

        if dump_format == 'hex':
            return '%032x' % value.int

        if dump_format == 'int':
            return value.int

        return str(value)
