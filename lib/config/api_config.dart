/// Backend URLs ¡ª change [backendHost] when your PC LAN / hotspot IP changes.
class ApiConfig {
  static const String backendHost = '10.100.95.30';

  static const String baseUrl = 'http://$backendHost:8000';
  static const String uploadUrl = '$baseUrl/upload';
  static const String healthUrl = '$baseUrl/health';
  static const String wsUrl = 'ws://$backendHost:8000/ws/transcribe';
}
