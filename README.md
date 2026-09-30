# Interview Alert App（面试邀约提醒）

一个帮助求职者管理面试安排的应用：

- **`interview_calendar/`** — Flutter 客户端（Android / iOS / 桌面 / Web），面试日历与提醒，内置 AI 助手抽取面试信息
- **`backend/`** — Python 后端，解析面试邀约邮件（ICS）、数据存储与 API 服务
- **`spike.py` / `spike.ics`** — ICS 解析与日历订阅的原型验证

## 快速开始

### 后端

```bash
pip install -r requirements.txt
cp config.example.yaml config.yaml   # 按需修改配置
```

### Flutter 客户端

```bash
cd interview_calendar
flutter pub get
flutter run
```

## 配置

敏感配置（API 密钥、账号等）写在 `config.yaml`，该文件已被 `.gitignore` 排除，请参考 `config.example.yaml` 填写。

## Android 打包

签名密钥（`*.jks` / `key.properties`）与构建日志均已排除在版本库之外。
