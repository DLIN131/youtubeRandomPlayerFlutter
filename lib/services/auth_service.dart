import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user_info.dart';

class AuthService {
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    serverClientId: '959560237311-13dbj26mjffjcph7r49pq3c57lbvpgrr.apps.googleusercontent.com',
    scopes: [
      'profile',
      'email',
      'https://www.googleapis.com/auth/youtube',
    ],
  );

  UserInfo? _currentUserInfo;
  String? _oauthToken; // Google OAuth token

  UserInfo? get currentUserInfo => _currentUserInfo;
  String? get oauthToken => _oauthToken;
  bool get isLoggedIn => _currentUserInfo != null;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _oauthToken = prefs.getString('oauth_token');
    
    if (_oauthToken != null && _oauthToken!.isNotEmpty) {
      final success = await _verifyGoogleToken();
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

      _currentUserInfo = UserInfo(
        userId: account.id,
        username: account.displayName ?? 'User',
        email: account.email,
        avatar: account.photoUrl ?? '',
      );
      _oauthToken = token;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('oauth_token', _oauthToken!);
      
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('Google Sign-In Error: $e');
      return false;
    }
  }

  Future<bool> _verifyGoogleToken() async {
    try {
      final account = await _googleSignIn.signInSilently();
      if (account != null) {
        final auth = await account.authentication;
        if (auth.accessToken != null) {
          _oauthToken = auth.accessToken;
          _currentUserInfo = UserInfo(
            userId: account.id,
            username: account.displayName ?? 'User',
            email: account.email,
            avatar: account.photoUrl ?? '',
          );
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> logout() async {
    await _googleSignIn.signOut();
    _currentUserInfo = null;
    _oauthToken = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('oauth_token');
  }
}
