import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// FR-8: encrypted backup of the SQLite database (transcript-only by default;
/// audio stays on device — it's large and re-derivable is false, but the
/// transcript IS the canonical record per plan principle #2).
///
/// Format: [magic 'RCL1'][salt 16][nonce 12][ciphertext+tag]
/// Cipher: AES-256-GCM, key = PBKDF2-HMAC-SHA256(passphrase, salt, 150k iters).
class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  static const _magic = 'RCL1';
  static const _iterations = 150000;

  final _aes = AesGcm.with256bits();

  Future<SecretKey> _deriveKey(String passphrase, List<int> salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _iterations,
      bits: 256,
    );
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  /// Encrypts [dbPath] into the app documents dir; returns the backup path.
  /// User then shares/uploads it to Drive with the system share-sheet.
  Future<String> export(String dbPath, String passphrase) async {
    final plain = await File(dbPath).readAsBytes();
    final salt = SecretKeyData.random(length: 16).bytes;
    final key = await _deriveKey(passphrase, salt);
    final box = await _aes.encrypt(plain, secretKey: key);

    final out = BytesBuilder();
    out.add(utf8.encode(_magic));
    out.add(salt);
    out.add(box.nonce);
    out.add(box.cipherText);
    out.add(box.mac.bytes);

    final dir = await getApplicationDocumentsDirectory();
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final path = p.join(dir.path, 'recall_backup_$stamp.rclbak');
    await File(path).writeAsBytes(out.toBytes());
    return path;
  }

  /// Decrypts a backup file and overwrites the current DB. App must reopen DB.
  Future<void> restore(String backupPath, String passphrase, String dbPath) async {
    final raw = await File(backupPath).readAsBytes();
    final magic = utf8.decode(raw.sublist(0, 4));
    if (magic != _magic) {
      throw const FormatException('Not a Recall backup file');
    }
    final salt = raw.sublist(4, 20);
    final nonce = raw.sublist(20, 32);
    final macLen = 16;
    final cipherText = raw.sublist(32, raw.length - macLen);
    final mac = Mac(raw.sublist(raw.length - macLen));

    final key = await _deriveKey(passphrase, salt);
    final plain = await _aes.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: key,
    ); // throws SecretBoxAuthenticationError on wrong passphrase
    await File(dbPath).writeAsBytes(plain, flush: true);
  }
}
