import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'session.dart';

/*
 * A port of the web's lib/files.js: files on Cloudflare R2 through the MOIS file service
 * (web/worker, 117) — a short-lived signed link to read or write '<bucket>/<path>'. A file not
 * on R2 yet is read from Supabase Storage, as on the web.
 */
const _api = String.fromEnvironment('FILES_API', defaultValue: 'https://mois.swahzitech.workers.dev');

Future<Map<String, dynamic>> _sign(String key, bool write, [String download = '']) async {
  final token = db.auth.currentSession?.accessToken;
  if (token == null) return {'error': 'Sign in first.'};
  try {
    final r = await http.post(Uri.parse('$_api/api/files/sign'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
        body: jsonEncode({'key': key, 'write': write, if (download.isNotEmpty) 'download': download}));
    final isJson = (r.headers['content-type'] ?? '').contains('json');
    if (r.statusCode == 404 || r.statusCode == 405 || r.statusCode >= 500 || !isJson) return {'unavailable': true};
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode >= 400) return {'error': body['error'] ?? "We couldn't reach the file store."};
    return body;
  } catch (_) {
    return {'unavailable': true};
  }
}

/// A link to read a stored file (10 minutes), or null
Future<String?> signedUrl(String bucket, String? path, {String download = ''}) async {
  if (path == null || path.isEmpty) return null;
  final s = await _sign('$bucket/$path', false, download);
  if (s['url'] != null) return s['url'] as String;
  try {
    return await db.storage.from(bucket).createSignedUrl(path, 600);
  } catch (_) {
    return null;
  }
}

/// Save a file at bucket/path; throws a plain message when it fails
Future<void> uploadFile(String bucket, String path, Uint8List bytes, String contentType) async {
  final s = await _sign('$bucket/$path', true);
  if (s['unavailable'] == true) {
    await db.storage.from(bucket).uploadBinary(path, bytes);
    return;
  }
  if (s['error'] != null) throw '${s['error']}';
  final r = await http.put(Uri.parse('${s['url']}'), headers: {'Content-Type': contentType}, body: bytes);
  if (r.statusCode >= 300) throw r.body.isNotEmpty ? r.body : "The file wasn't saved.";
}
