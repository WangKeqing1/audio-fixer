import 'audio_track.dart';

/// Validates replacement/addition values, never deletion. The original raw tag
/// is retained unless the user selects a non-empty, valid replacement.
String? validateAudioFieldValue(AudioField field, String value) {
  if (value.trim().isEmpty) return '${field.label}不能为空。';
  if (value.contains('\x00')) return '${field.label}不能包含空字符。';
  final limit = switch (field) {
    AudioField.lyrics => 1024 * 1024,
    AudioField.comment => 16384,
    _ => 4096,
  };
  if (value.length > limit) return '${field.label}不能超过 $limit 个字符。';
  if (field.isNumeric) {
    final text = value.trim();
    final number = RegExp(r'^[0-9]+$').hasMatch(text)
        ? int.tryParse(text)
        : null;
    final maximum = field == AudioField.year ? 9999 : 65535;
    if (number == null || number < 1 || number > maximum) {
      return '${field.label}须为 1–$maximum 的整数。';
    }
  }
  return null;
}

/// Checks paired counters using the proposed values together with retained
/// tags. Existing unrelated malformed pairs do not block an unrelated repair.
String? validateAudioFieldChanges(
  AudioTrack track,
  Map<AudioField, String> changes,
) {
  if (changes.isEmpty) return '请至少修改一项资料。';
  for (final entry in changes.entries) {
    final error = validateAudioFieldValue(entry.key, entry.value);
    if (error != null) return error;
  }
  for (final (number, total) in const [
    (AudioField.trackNumber, AudioField.trackTotal),
    (AudioField.discNumber, AudioField.discTotal),
  ]) {
    if (!changes.containsKey(number) && !changes.containsKey(total)) continue;
    final index = int.tryParse(changes[number] ?? track.valueOf(number) ?? '');
    final count = int.tryParse(changes[total] ?? track.valueOf(total) ?? '');
    if (index != null && count != null && index > count) {
      return '${number.label}不能大于${total.label}。';
    }
  }
  return null;
}
