import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/supabase_service.dart';

class _Colors {
  static const bg = Color(0xFFF8FAFC);
  static const card = Color(0xFFFFFFFF);
  static const textMain = Color(0xFF1E293B);
  static const textSub = Color(0xFF64748B);
  static const border = Color(0xFFE2E8F0);
  static const primary = Color(0xFF007BFF);
}

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _fullNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _showPassword = false;
  bool _isLoading = false;

  @override
  void dispose() {
    _fullNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  final _dbService = SupabaseService.instance;

  Future<void> _handleRegister() async {
    final fullName = _fullNameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (fullName.isEmpty || email.isEmpty || password.isEmpty || confirmPassword.isEmpty) {
      _alert('Missing Fields', 'Please fill out all fields.');
      return;
    }
    if (password != confirmPassword) {
      _alert('Password Mismatch', 'Your passwords do not match.');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final res = await _dbService.signUp(email, password, fullName);

      if (res.session != null) {
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Registration Successful'),
            content: const Text('Your account has been created. You can now log in.'),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
          ),
        );
        if (mounted) Navigator.of(context).pushReplacementNamed('/login');
      } else {
        if (mounted) {
          await showDialog(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Check your Email'),
              content: const Text(
                  'We sent a verification link to your inbox. Please verify your account to log in.'),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
            ),
          );
          if (mounted) Navigator.of(context).pushReplacementNamed('/login');
        }
      }
    } on AuthException catch (e) {
      _alert('Registration Failed', e.message);
    } catch (e) {
      _alert('Registration Failed', e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleGoogleAuth() async {
    setState(() => _isLoading = true);
    try {
      await _dbService.signInWithGoogle();
    } catch (e) {
      _alert('Google Auth Failed', e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _alert(String title, String message) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _Colors.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(25, 30, 25, 50),
          child: Column(
            children: [
              // Header
              Stack(
                alignment: Alignment.topCenter,
                children: [
                  Positioned(
                    left: 0,
                    top: 20,
                    child: InkWell(
                      onTap: () => Navigator.of(context).pop(),
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: const BoxDecoration(color: _Colors.card, shape: BoxShape.circle),
                        child: const Icon(Icons.arrow_back, size: 24, color: _Colors.textMain),
                      ),
                    ),
                  ),
                  Column(
                    children: [
                      Container(
                        width: 70,
                        height: 70,
                        margin: const EdgeInsets.only(bottom: 15),
                        decoration: const BoxDecoration(color: _Colors.primary, shape: BoxShape.circle),
                        child: const Icon(Icons.person_add_alt_outlined, size: 36, color: Colors.white),
                      ),
                      const Text('Create Account',
                          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: _Colors.textMain)),
                      const SizedBox(height: 5),
                      const Text('Set up your Guardian profile', style: TextStyle(fontSize: 14, color: _Colors.textSub)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 30),

              // Form
              Container(
                padding: const EdgeInsets.all(25),
                decoration: BoxDecoration(
                  color: _Colors.card,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10)],
                ),
                child: Column(
                  children: [
                    _LabeledInput(label: 'Full Name', controller: _fullNameController, icon: Icons.person_outline, hint: 'Juan Dela Cruz'),
                    const SizedBox(height: 18),
                    _LabeledInput(
                      label: 'Email Address',
                      controller: _emailController,
                      icon: Icons.mail_outline,
                      hint: 'guardian@example.com',
                      keyboardType: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 18),
                    _LabeledInput(
                      label: 'Password',
                      controller: _passwordController,
                      icon: Icons.lock_outline,
                      hint: '••••••••',
                      obscureText: !_showPassword,
                      suffixIcon: IconButton(
                        icon: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                            size: 20, color: _Colors.textSub),
                        onPressed: () => setState(() => _showPassword = !_showPassword),
                      ),
                    ),
                    const SizedBox(height: 18),
                    _LabeledInput(
                      label: 'Confirm Password',
                      controller: _confirmPasswordController,
                      icon: Icons.lock_outline,
                      hint: '••••••••',
                      obscureText: !_showPassword,
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _handleRegister,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _Colors.primary,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text(_isLoading ? 'Creating Account...' : 'Sign Up',
                            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Row(
                        children: const [
                          Expanded(child: Divider(color: _Colors.border)),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 10),
                            child: Text('OR', style: TextStyle(color: _Colors.textSub, fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                          Expanded(child: Divider(color: _Colors.border)),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: OutlinedButton.icon(
                        onPressed: _isLoading ? null : _handleGoogleAuth,
                        style: OutlinedButton.styleFrom(
                          backgroundColor: Colors.white,
                          side: const BorderSide(color: _Colors.border),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        icon: const Icon(Icons.g_mobiledata, color: Color(0xFFDB4437), size: 24),
                        label: const Text('Sign Up with Google',
                            style: TextStyle(color: _Colors.textMain, fontSize: 16, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),

              Padding(
                padding: const EdgeInsets.only(top: 30),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('Already have an account? ', style: TextStyle(color: _Colors.textSub, fontSize: 14)),
                    GestureDetector(
                      onTap: () => Navigator.of(context).pushReplacementNamed('/login'),
                      child: const Text('Login Here',
                          style: TextStyle(color: _Colors.primary, fontSize: 14, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LabeledInput extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final IconData icon;
  final String hint;
  final bool obscureText;
  final Widget? suffixIcon;
  final TextInputType? keyboardType;

  const _LabeledInput({
    required this.label,
    required this.controller,
    required this.icon,
    required this.hint,
    this.obscureText = false,
    this.suffixIcon,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _Colors.textSub, letterSpacing: 0.5)),
        const SizedBox(height: 8),
        Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 15),
          decoration: BoxDecoration(
            color: _Colors.bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _Colors.border),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: _Colors.textSub),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: controller,
                  obscureText: obscureText,
                  keyboardType: keyboardType,
                  style: const TextStyle(color: _Colors.textMain, fontSize: 16),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: const TextStyle(color: _Colors.textSub),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              if (suffixIcon != null) suffixIcon!,
            ],
          ),
        ),
      ],
    );
  }
}