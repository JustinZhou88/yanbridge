/// Thrown when the microphone is unavailable, denied, or unsuitable.
class MicInputException implements Exception {
  MicInputException(this.message);
  final String message;

  @override
  String toString() => message;
}
