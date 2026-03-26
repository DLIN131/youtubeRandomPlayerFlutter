import 'package:dio/dio.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user_info.dart';

class AuthService {
  static const String _baseUrl = 'https://ytdl-server-byvu.onrender.com';
  
  final Dio _dio = Dio(BaseOptions(baseUrl: _baseUrl));
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    clientId: '959560237311-13dbj26mjffjcph7r49pq3c57lbvpgrr.apps.googleusercontent.com',
    serverClientId: '959560237311-13dbj26mjffjcph7r49pq3c57lbvpgrr.apps.googleusercontent.com',
    scopes: [
      'profile',
      'email',
      'https://www.googleapis.com/auth/youtube.readonly',
    ],
  );

  UserInfo? _currentUserInfo;
  String? _accessToken; // JWT from backend
  String? _oauthToken; // Google OAuth token

  UserInfo? get currentUserInfo => _currentUserInfo;
  String? get oauthToken => _oauthToken;
  bool get isLoggedIn => _currentUserInfo != null;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString('access_token');
    _oauthToken = prefs.getString('oauth_token');
    
    if (_accessToken != null && _accessToken!.isNotEmpty) {
      final success = await _verifyBackendToken();
      if (!success) {
        await logout();
      }
    }
  }

  Future<bool> login() async {
    try {
      final GoogleSignInAccount? account = await _googleSignIn.signIn();
      if (account == null) {
        return false; // User canceled login
      }
      
      final GoogleSignInAuthentication auth = await account.authentication;
      final token = auth.accessToken;
      
      if (token == null) return false;

      // Authenticate with custom backend
      final res = await _dio.post('/google-login', data: {
        'access_token': token,
      });

      if (res.statusCode == 200 || res.statusCode == 201) {
        final data = res.data['data'] ?? res.data;
        _currentUserInfo = UserInfo.fromJson(data['user'] ?? {});
        _accessToken = data['token'];
        _oauthToken = token;

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('access_token', _accessToken!);
        await prefs.setString('oauth_token', _oauthToken!);
        
        return true;
      }
      return false;
    } catch (e) {
      // ignore: avoid_print
      print('Google Sign-In Error: $e');
      return false;
    }
  }

  Future<bool> _verifyBackendToken() async {
    try {
      final res = await _dio.get('/protect', options: Options(
        headers: {
          'Authorization': 'Bearer $_accessToken',
        },
      ));
      
      if (res.statusCode == 200) {
        // Assume backend returns user info or we just keep existing ones if valid
        // If the backend returns user object here in protect route, we could parse it,
        // but for now, returning true is enough.
        // Let's silently re-login with Google to ensure we have fresh user info 
        // and OAuth token if it's expired.
        final account = await _googleSignIn.signInSilently();
        if (account != null) {
             final auth = await account.authentication;
             _oauthToken = auth.accessToken;
             // also we need user data, but we don't have it saved locally. Let's just sign in again fully 
             // to get user info from /google-login if needed.
             // Actually, the original Vue code stored userInfo in unpersisted pinia state, 
             // so on refresh it called authLogin which checked /protect and if valid it did nothing (except it lost userinfo if not persisted).
             // Let's just do signInSilently and then call /google-login again to ensure we get user info.
             if (_oauthToken != null) {
               final r = await _dio.post('/google-login', data: {'access_token': _oauthToken});
               final data = r.data['data'] ?? r.data;
               _currentUserInfo = UserInfo.fromJson(data['user'] ?? {});
               return true;
             }
        }
        return false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> logout() async {
    await _googleSignIn.signOut();
    _currentUserInfo = null;
    _accessToken = null;
    _oauthToken = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('access_token');
    await prefs.remove('oauth_token');
  }
}
