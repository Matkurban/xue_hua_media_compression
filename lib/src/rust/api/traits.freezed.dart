// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'traits.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$MediaError {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MediaError);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'MediaError()';
}


}

/// @nodoc
class $MediaErrorCopyWith<$Res>  {
$MediaErrorCopyWith(MediaError _, $Res Function(MediaError) __);
}


/// Adds pattern-matching-related methods to [MediaError].
extension MediaErrorPatterns on MediaError {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( MediaError_UnsupportedFormat value)?  unsupportedFormat,TResult Function( MediaError_Decode value)?  decode,TResult Function( MediaError_Encode value)?  encode,TResult Function( MediaError_HardwareUnavailable value)?  hardwareUnavailable,TResult Function( MediaError_Mux value)?  mux,TResult Function( MediaError_Io value)?  io,TResult Function( MediaError_Native value)?  native,required TResult orElse(),}){
final _that = this;
switch (_that) {
case MediaError_UnsupportedFormat() when unsupportedFormat != null:
return unsupportedFormat(_that);case MediaError_Decode() when decode != null:
return decode(_that);case MediaError_Encode() when encode != null:
return encode(_that);case MediaError_HardwareUnavailable() when hardwareUnavailable != null:
return hardwareUnavailable(_that);case MediaError_Mux() when mux != null:
return mux(_that);case MediaError_Io() when io != null:
return io(_that);case MediaError_Native() when native != null:
return native(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( MediaError_UnsupportedFormat value)  unsupportedFormat,required TResult Function( MediaError_Decode value)  decode,required TResult Function( MediaError_Encode value)  encode,required TResult Function( MediaError_HardwareUnavailable value)  hardwareUnavailable,required TResult Function( MediaError_Mux value)  mux,required TResult Function( MediaError_Io value)  io,required TResult Function( MediaError_Native value)  native,}){
final _that = this;
switch (_that) {
case MediaError_UnsupportedFormat():
return unsupportedFormat(_that);case MediaError_Decode():
return decode(_that);case MediaError_Encode():
return encode(_that);case MediaError_HardwareUnavailable():
return hardwareUnavailable(_that);case MediaError_Mux():
return mux(_that);case MediaError_Io():
return io(_that);case MediaError_Native():
return native(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( MediaError_UnsupportedFormat value)?  unsupportedFormat,TResult? Function( MediaError_Decode value)?  decode,TResult? Function( MediaError_Encode value)?  encode,TResult? Function( MediaError_HardwareUnavailable value)?  hardwareUnavailable,TResult? Function( MediaError_Mux value)?  mux,TResult? Function( MediaError_Io value)?  io,TResult? Function( MediaError_Native value)?  native,}){
final _that = this;
switch (_that) {
case MediaError_UnsupportedFormat() when unsupportedFormat != null:
return unsupportedFormat(_that);case MediaError_Decode() when decode != null:
return decode(_that);case MediaError_Encode() when encode != null:
return encode(_that);case MediaError_HardwareUnavailable() when hardwareUnavailable != null:
return hardwareUnavailable(_that);case MediaError_Mux() when mux != null:
return mux(_that);case MediaError_Io() when io != null:
return io(_that);case MediaError_Native() when native != null:
return native(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String field0)?  unsupportedFormat,TResult Function( String field0)?  decode,TResult Function( String field0)?  encode,TResult Function( String field0)?  hardwareUnavailable,TResult Function( String field0)?  mux,TResult Function( String field0)?  io,TResult Function( PlatformInt64 code,  String msg)?  native,required TResult orElse(),}) {final _that = this;
switch (_that) {
case MediaError_UnsupportedFormat() when unsupportedFormat != null:
return unsupportedFormat(_that.field0);case MediaError_Decode() when decode != null:
return decode(_that.field0);case MediaError_Encode() when encode != null:
return encode(_that.field0);case MediaError_HardwareUnavailable() when hardwareUnavailable != null:
return hardwareUnavailable(_that.field0);case MediaError_Mux() when mux != null:
return mux(_that.field0);case MediaError_Io() when io != null:
return io(_that.field0);case MediaError_Native() when native != null:
return native(_that.code,_that.msg);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String field0)  unsupportedFormat,required TResult Function( String field0)  decode,required TResult Function( String field0)  encode,required TResult Function( String field0)  hardwareUnavailable,required TResult Function( String field0)  mux,required TResult Function( String field0)  io,required TResult Function( PlatformInt64 code,  String msg)  native,}) {final _that = this;
switch (_that) {
case MediaError_UnsupportedFormat():
return unsupportedFormat(_that.field0);case MediaError_Decode():
return decode(_that.field0);case MediaError_Encode():
return encode(_that.field0);case MediaError_HardwareUnavailable():
return hardwareUnavailable(_that.field0);case MediaError_Mux():
return mux(_that.field0);case MediaError_Io():
return io(_that.field0);case MediaError_Native():
return native(_that.code,_that.msg);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String field0)?  unsupportedFormat,TResult? Function( String field0)?  decode,TResult? Function( String field0)?  encode,TResult? Function( String field0)?  hardwareUnavailable,TResult? Function( String field0)?  mux,TResult? Function( String field0)?  io,TResult? Function( PlatformInt64 code,  String msg)?  native,}) {final _that = this;
switch (_that) {
case MediaError_UnsupportedFormat() when unsupportedFormat != null:
return unsupportedFormat(_that.field0);case MediaError_Decode() when decode != null:
return decode(_that.field0);case MediaError_Encode() when encode != null:
return encode(_that.field0);case MediaError_HardwareUnavailable() when hardwareUnavailable != null:
return hardwareUnavailable(_that.field0);case MediaError_Mux() when mux != null:
return mux(_that.field0);case MediaError_Io() when io != null:
return io(_that.field0);case MediaError_Native() when native != null:
return native(_that.code,_that.msg);case _:
  return null;

}
}

}

/// @nodoc


class MediaError_UnsupportedFormat extends MediaError {
  const MediaError_UnsupportedFormat(this.field0): super._();
  

 final  String field0;

/// Create a copy of MediaError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MediaError_UnsupportedFormatCopyWith<MediaError_UnsupportedFormat> get copyWith => _$MediaError_UnsupportedFormatCopyWithImpl<MediaError_UnsupportedFormat>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MediaError_UnsupportedFormat&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'MediaError.unsupportedFormat(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $MediaError_UnsupportedFormatCopyWith<$Res> implements $MediaErrorCopyWith<$Res> {
  factory $MediaError_UnsupportedFormatCopyWith(MediaError_UnsupportedFormat value, $Res Function(MediaError_UnsupportedFormat) _then) = _$MediaError_UnsupportedFormatCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$MediaError_UnsupportedFormatCopyWithImpl<$Res>
    implements $MediaError_UnsupportedFormatCopyWith<$Res> {
  _$MediaError_UnsupportedFormatCopyWithImpl(this._self, this._then);

  final MediaError_UnsupportedFormat _self;
  final $Res Function(MediaError_UnsupportedFormat) _then;

/// Create a copy of MediaError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(MediaError_UnsupportedFormat(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class MediaError_Decode extends MediaError {
  const MediaError_Decode(this.field0): super._();
  

 final  String field0;

/// Create a copy of MediaError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MediaError_DecodeCopyWith<MediaError_Decode> get copyWith => _$MediaError_DecodeCopyWithImpl<MediaError_Decode>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MediaError_Decode&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'MediaError.decode(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $MediaError_DecodeCopyWith<$Res> implements $MediaErrorCopyWith<$Res> {
  factory $MediaError_DecodeCopyWith(MediaError_Decode value, $Res Function(MediaError_Decode) _then) = _$MediaError_DecodeCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$MediaError_DecodeCopyWithImpl<$Res>
    implements $MediaError_DecodeCopyWith<$Res> {
  _$MediaError_DecodeCopyWithImpl(this._self, this._then);

  final MediaError_Decode _self;
  final $Res Function(MediaError_Decode) _then;

/// Create a copy of MediaError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(MediaError_Decode(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class MediaError_Encode extends MediaError {
  const MediaError_Encode(this.field0): super._();
  

 final  String field0;

/// Create a copy of MediaError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MediaError_EncodeCopyWith<MediaError_Encode> get copyWith => _$MediaError_EncodeCopyWithImpl<MediaError_Encode>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MediaError_Encode&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'MediaError.encode(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $MediaError_EncodeCopyWith<$Res> implements $MediaErrorCopyWith<$Res> {
  factory $MediaError_EncodeCopyWith(MediaError_Encode value, $Res Function(MediaError_Encode) _then) = _$MediaError_EncodeCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$MediaError_EncodeCopyWithImpl<$Res>
    implements $MediaError_EncodeCopyWith<$Res> {
  _$MediaError_EncodeCopyWithImpl(this._self, this._then);

  final MediaError_Encode _self;
  final $Res Function(MediaError_Encode) _then;

/// Create a copy of MediaError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(MediaError_Encode(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class MediaError_HardwareUnavailable extends MediaError {
  const MediaError_HardwareUnavailable(this.field0): super._();
  

 final  String field0;

/// Create a copy of MediaError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MediaError_HardwareUnavailableCopyWith<MediaError_HardwareUnavailable> get copyWith => _$MediaError_HardwareUnavailableCopyWithImpl<MediaError_HardwareUnavailable>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MediaError_HardwareUnavailable&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'MediaError.hardwareUnavailable(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $MediaError_HardwareUnavailableCopyWith<$Res> implements $MediaErrorCopyWith<$Res> {
  factory $MediaError_HardwareUnavailableCopyWith(MediaError_HardwareUnavailable value, $Res Function(MediaError_HardwareUnavailable) _then) = _$MediaError_HardwareUnavailableCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$MediaError_HardwareUnavailableCopyWithImpl<$Res>
    implements $MediaError_HardwareUnavailableCopyWith<$Res> {
  _$MediaError_HardwareUnavailableCopyWithImpl(this._self, this._then);

  final MediaError_HardwareUnavailable _self;
  final $Res Function(MediaError_HardwareUnavailable) _then;

/// Create a copy of MediaError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(MediaError_HardwareUnavailable(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class MediaError_Mux extends MediaError {
  const MediaError_Mux(this.field0): super._();
  

 final  String field0;

/// Create a copy of MediaError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MediaError_MuxCopyWith<MediaError_Mux> get copyWith => _$MediaError_MuxCopyWithImpl<MediaError_Mux>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MediaError_Mux&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'MediaError.mux(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $MediaError_MuxCopyWith<$Res> implements $MediaErrorCopyWith<$Res> {
  factory $MediaError_MuxCopyWith(MediaError_Mux value, $Res Function(MediaError_Mux) _then) = _$MediaError_MuxCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$MediaError_MuxCopyWithImpl<$Res>
    implements $MediaError_MuxCopyWith<$Res> {
  _$MediaError_MuxCopyWithImpl(this._self, this._then);

  final MediaError_Mux _self;
  final $Res Function(MediaError_Mux) _then;

/// Create a copy of MediaError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(MediaError_Mux(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class MediaError_Io extends MediaError {
  const MediaError_Io(this.field0): super._();
  

 final  String field0;

/// Create a copy of MediaError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MediaError_IoCopyWith<MediaError_Io> get copyWith => _$MediaError_IoCopyWithImpl<MediaError_Io>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MediaError_Io&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'MediaError.io(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $MediaError_IoCopyWith<$Res> implements $MediaErrorCopyWith<$Res> {
  factory $MediaError_IoCopyWith(MediaError_Io value, $Res Function(MediaError_Io) _then) = _$MediaError_IoCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$MediaError_IoCopyWithImpl<$Res>
    implements $MediaError_IoCopyWith<$Res> {
  _$MediaError_IoCopyWithImpl(this._self, this._then);

  final MediaError_Io _self;
  final $Res Function(MediaError_Io) _then;

/// Create a copy of MediaError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(MediaError_Io(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class MediaError_Native extends MediaError {
  const MediaError_Native({required this.code, required this.msg}): super._();
  

 final  PlatformInt64 code;
 final  String msg;

/// Create a copy of MediaError
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MediaError_NativeCopyWith<MediaError_Native> get copyWith => _$MediaError_NativeCopyWithImpl<MediaError_Native>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MediaError_Native&&(identical(other.code, code) || other.code == code)&&(identical(other.msg, msg) || other.msg == msg));
}


@override
int get hashCode => Object.hash(runtimeType,code,msg);

@override
String toString() {
  return 'MediaError.native(code: $code, msg: $msg)';
}


}

/// @nodoc
abstract mixin class $MediaError_NativeCopyWith<$Res> implements $MediaErrorCopyWith<$Res> {
  factory $MediaError_NativeCopyWith(MediaError_Native value, $Res Function(MediaError_Native) _then) = _$MediaError_NativeCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 code, String msg
});




}
/// @nodoc
class _$MediaError_NativeCopyWithImpl<$Res>
    implements $MediaError_NativeCopyWith<$Res> {
  _$MediaError_NativeCopyWithImpl(this._self, this._then);

  final MediaError_Native _self;
  final $Res Function(MediaError_Native) _then;

/// Create a copy of MediaError
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? code = null,Object? msg = null,}) {
  return _then(MediaError_Native(
code: null == code ? _self.code : code // ignore: cast_nullable_to_non_nullable
as PlatformInt64,msg: null == msg ? _self.msg : msg // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
