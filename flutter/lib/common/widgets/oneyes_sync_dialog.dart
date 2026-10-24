import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/oneyes_client.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

/// 弹出 OneYes 配置中心云端同步与合并窗口
void showOneYesSyncDialog({
  List<TextEditingController>? serverControllers,
  List<RxString>? serverErrMsgs,
  VoidCallback? onSyncSuccess,
}) async {
  // 读取本地已保存的凭据
  String serverUrl = bind.mainGetLocalOption(key: kOptionOneYesServerUrl);
  if (serverUrl.isEmpty) {
    serverUrl = 'http://192.168.10.66:8890';
  }
  final email = bind.mainGetLocalOption(key: kOptionOneYesEmail);
  final password = bind.mainGetLocalOption(key: kOptionOneYesPassword);
  final rememberVal = bind.mainGetLocalOption(key: kOptionOneYesRemember);
  bool remember = rememberVal != 'N';

  final serverUrlCtrl = TextEditingController(text: serverUrl);
  final emailCtrl = TextEditingController(text: email);
  final pwdCtrl = TextEditingController(text: password);

  bool obscurePwd = true;
  String syncStrategy = 'remote_first'; // remote_first, local_first, pull_only, push_only
  bool isProcessing = false;
  String statusMsg = '';
  String errorMsg = '';

  gFFI.dialogManager.show((setState, close, context) {
    Future<void> doSync() async {
      final sUrl = serverUrlCtrl.text.trim();
      final mail = emailCtrl.text.trim();
      final pwd = pwdCtrl.text;

      if (sUrl.isEmpty) {
        setState(() => errorMsg = translate('Server address cannot be empty'));
        return;
      }
      if (mail.isEmpty) {
        setState(() => errorMsg = translate('Email cannot be empty'));
        return;
      }
      if (pwd.isEmpty) {
        setState(() => errorMsg = translate('Password cannot be empty'));
        return;
      }

      setState(() {
        isProcessing = true;
        errorMsg = '';
        statusMsg = '正在派生端到端加解密密钥 (PBKDF2-100k)...';
      });

      try {
        final client = OneYesClient(
          serverUrl: sUrl,
          email: mail,
          appName: 'rustdesk',
        );

        await client.init(pwd);

        setState(() {
          statusMsg = '正在连接 OneYes 配置中心...';
        });

        // 尝试登录；如果未注册则自动注册账号
        try {
          final loginOk = await client.login();
          if (!loginOk) {
            await client.register();
          }
        } catch (_) {
          // 如果登录或注册报已存在/冲突，则继续执行 pull/push（服务端基于 Auth-Key 鉴权）
        }

        // 1. 获取当前本地配置
        setState(() {
          statusMsg = '正在获取本机当前配置与服务器配置...';
        });

        final idServer = await bind.mainGetOption(key: 'custom-rendezvous-server');
        final relayServer = await bind.mainGetOption(key: 'relay-server');
        final apiServer = await bind.mainGetOption(key: 'api-server');
        final key = await bind.mainGetOption(key: 'key');

        Map<String, dynamic> localOptions = {};
        try {
          final optionsJson = await bind.mainGetOptions();
          localOptions = json.decode(optionsJson);
        } catch (_) {}

        final localData = <String, dynamic>{
          'server': {
            'id_server': idServer,
            'relay_server': relayServer,
            'api_server': apiServer,
            'key': key,
          },
          'options': localOptions,
        };

        Map<String, dynamic> finalData = {};
        int finalVersion = 0;

        if (syncStrategy == 'push_only') {
          setState(() => statusMsg = '正在加密并上传本地配置到 OneYes...');
          finalVersion = await client.push(localData, remark: 'RustDesk 本机配置上传');
          finalData = localData;
        } else if (syncStrategy == 'pull_only') {
          setState(() => statusMsg = '正在从 OneYes 获取并解密远端配置...');
          final pullRes = await client.pull();
          if (pullRes.config == null) {
            throw RuntimeErrorException('OneYes 云端暂无 rustdesk 的配置数据');
          }
          finalData = pullRes.config!;
          finalVersion = pullRes.version;
        } else {
          // remote_first 或 local_first 智能合并
          setState(() => statusMsg = '正在拉取远端配置并执行智能深度合并...');
          final pullRes = await client.pull();
          final remoteConfig = pullRes.config;

          if (remoteConfig == null) {
            setState(() => statusMsg = '云端尚无配置，首次加密上传本地配置...');
            finalVersion = await client.push(localData, remark: '首次同步本地配置');
            finalData = localData;
          } else {
            if (syncStrategy == 'remote_first') {
              finalData = OneYesClient.deepMerge(localData, remoteConfig);
            } else {
              finalData = OneYesClient.deepMerge(remoteConfig, localData);
            }

            // 检查合并后是否有本地新增项需要回推到远端
            if (!OneYesClient.mapEquals(finalData, remoteConfig)) {
              setState(() => statusMsg = '合并产生新配置，正在同步更新云端版本...');
              finalVersion = await client.push(finalData, remark: '客户端配置同步合并上传');
            } else {
              finalVersion = pullRes.version;
            }
          }
        }

        // 2. 将最终合并结果应用到本机 RustDesk 运行环境
        setState(() => statusMsg = '正在将合并后的配置应用至本机...');

        // 应用 options
        if (finalData['options'] is Map<String, dynamic>) {
          final optionsMap = finalData['options'] as Map<String, dynamic>;
          await bind.mainSetOptions(json: json.encode(optionsMap));
        }

        // 应用 server 配置
        if (finalData['server'] is Map<String, dynamic>) {
          final sMap = finalData['server'] as Map<String, dynamic>;
          final sc = ServerConfig(
            idServer: (sMap['id_server'] ?? '').toString(),
            relayServer: (sMap['relay_server'] ?? '').toString(),
            apiServer: (sMap['api_server'] ?? '').toString(),
            key: (sMap['key'] ?? '').toString(),
          );
          await setServerConfig(serverControllers, serverErrMsgs, sc);
        }

        // 3. 记忆凭据
        await bind.mainSetLocalOption(
            key: kOptionOneYesServerUrl, value: sUrl);
        await bind.mainSetLocalOption(
            key: kOptionOneYesEmail, value: mail);
        await bind.mainSetLocalOption(
            key: kOptionOneYesRemember, value: remember ? 'Y' : 'N');
        if (remember) {
          await bind.mainSetLocalOption(
              key: kOptionOneYesPassword, value: pwd);
        } else {
          await bind.mainSetLocalOption(
              key: kOptionOneYesPassword, value: '');
        }

        setState(() {
          isProcessing = false;
          statusMsg = '';
        });

        showToast(
            'OneYes 云端配置已同步并合并成功 (版本: v$finalVersion)！');
        onSyncSuccess?.call();
        close();
      } catch (e) {
        setState(() {
          isProcessing = false;
          errorMsg = e.toString();
          statusMsg = '';
        });
      }
    }

    return CustomAlertDialog(
      title: Row(
        children: [
          Icon(Icons.cloud_sync_outlined, color: MyTheme.accent, size: 24),
          const SizedBox(width: 8),
          Text(translate('OneYes 云端配置同步')),
        ],
      ),
      contentBoxConstraints: const BoxConstraints(maxWidth: 480),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              translate('与 OneYes 配置中心 (66:8890) 实现端到端加密同步与多设备配置合并。主密码仅在本地派生密钥，配置明文绝不出网。'),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
            ),
            const SizedBox(height: 16),
            // 服务端地址
            TextField(
              controller: serverUrlCtrl,
              enabled: !isProcessing,
              decoration: InputDecoration(
                labelText: translate('OneYes 服务端地址'),
                hintText: 'http://192.168.10.66:8890',
                prefixIcon: const Icon(Icons.dns_outlined, size: 20),
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            // 账号/邮箱
            TextField(
              controller: emailCtrl,
              enabled: !isProcessing,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: translate('邮箱账号 (Email)'),
                hintText: 'user@example.com',
                prefixIcon: const Icon(Icons.person_outline, size: 20),
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            // 主密码
            TextField(
              controller: pwdCtrl,
              enabled: !isProcessing,
              obscureText: obscurePwd,
              decoration: InputDecoration(
                labelText: translate('主密码 (Master Password)'),
                prefixIcon: const Icon(Icons.lock_outline, size: 20),
                suffixIcon: IconButton(
                  icon: Icon(
                    obscurePwd ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    size: 20,
                  ),
                  onPressed: () => setState(() => obscurePwd = !obscurePwd),
                ),
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            // 合并策略
            DropdownButtonFormField<String>(
              value: syncStrategy,
              decoration: InputDecoration(
                labelText: translate('同步策略'),
                prefixIcon: const Icon(Icons.sync_alt, size: 20),
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'remote_first',
                  child: Text('云端优先合并 (推荐，双向智能合并)'),
                ),
                DropdownMenuItem(
                  value: 'local_first',
                  child: Text('本地优先合并 (以本机设置为主)'),
                ),
                DropdownMenuItem(
                  value: 'pull_only',
                  child: Text('仅拉取覆盖 (完全由云端覆盖本地)'),
                ),
                DropdownMenuItem(
                  value: 'push_only',
                  child: Text('仅推送本地 (用本机配置覆盖云端)'),
                ),
              ],
              onChanged: isProcessing
                  ? null
                  : (v) {
                      if (v != null) setState(() => syncStrategy = v);
                    },
            ),
            const SizedBox(height: 8),
            // 记住凭据
            Row(
              children: [
                Checkbox(
                  value: remember,
                  onChanged: isProcessing
                      ? null
                      : (v) => setState(() => remember = v ?? true),
                ),
                GestureDetector(
                  onTap: isProcessing
                      ? null
                      : () => setState(() => remember = !remember),
                  child: Text(
                    translate('在本地安全记住账号密码'),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
            if (isProcessing) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      statusMsg,
                      style: TextStyle(
                        fontSize: 12,
                        color: MyTheme.accent,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (errorMsg.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.red, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        errorMsg,
                        style: const TextStyle(color: Colors.red, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: isProcessing ? null : close,
          child: Text(translate('Cancel')),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.cloud_sync, size: 18),
          label: Text(translate('立即同步')),
          onPressed: isProcessing ? null : doSync,
        ),
      ],
    );
  }, clickMaskDismiss: false, backDismiss: false);
}
