class UserInfo {
  final String userId;
  final String username;
  final String email;
  final String avatar;

  UserInfo({
    required this.userId,
    required this.username,
    required this.email,
    required this.avatar,
  });

  factory UserInfo.fromJson(Map<String, dynamic> json) {
    return UserInfo(
      userId: json['userId'] ?? '',
      username: json['username'] ?? '',
      email: json['email'] ?? '',
      avatar: json['avatar'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'username': username,
      'email': email,
      'avatar': avatar,
    };
  }
}
