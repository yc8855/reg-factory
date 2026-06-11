# 更新日志

## 2026-06-12 — vision_solver 过 hCaptcha（canvas 点击 + 拖拽）

**新增**
- **`vision_solver` 新增 `canvas_grid` 模式**：解新版 hCaptcha。实测发现现代 hCaptcha 把**整个挑战渲染进单个 `<canvas>`（500×470）**，无任何可枚举/可点的 DOM tile，原 `grid_select`（点 DOM 元素）不适用。新 driver `solve_canvas_grid`：
  - **稳定截图**（`_shot_canvas_stable`）：先强制等图加载，再要求连续帧字节一致才采用，避免截到渐入/加载中的半成品。
  - **像素坐标点击**（`_click_canvas_cell`）：按 bbox/截图尺寸比换算 dpr，直接 `click(position=...)` 点 canvas 对应格中心。
  - **网格几何**（`overlay_grid_numbers` 四边内缩）：实测 500×470 上内缩 top0.30/bottom0.036/左右0.164，把编号网格框定到真实图块区，保证点中心对齐。
  - **题型自动判别**（`_infer_layout`）：题干含 "the item/thing"(单数) 且无 "all/each" → 单选（`vote_answer`，只点 1 格、永不空选）；"card/different" → 1×3 卡片单选；"select all" → 多选（`vote_picklist`）。空共识时兜底点最高票一格，避免空提交浪费轮次。
- **`vision_solver` 新增 `canvas_drag` 模式**：解拖拽类挑战（把 piece 拖到 target）。`solve_canvas_drag` + `vote_points`（各模型给 `FROM=(x,y) TO=(x,y)` 归一化坐标、取各点中位数抗离群）+ `_drag_on_canvas`（`page.mouse` down/move 分步带抖动/up 模拟人手）。预置 `presets/hcaptcha_drag.json`。
- 预置 `presets/hcaptcha.json` 改写为 `canvas_grid`（`frame_match=["frame=challenge"]`，题干 `#prompt-question`，提交 `.button-submit`）。

**测试**
- 点击型对 live demo（`https://accounts.hcaptcha.com/demo`）三个测试 sitekey 各跑 3 轮：**8/9 通过**，唯一失败为空选卡死，修复后（单选路由 + 兜底点击）复跑全过。
- 拖拽型 demo 不发拖拽题（三种探针证实该 demo + 测试 key 只发 "Tap the item provides shade" 一种 3×3 点击题），故用本地合成 canvas 谜题（蓝球拖进红框）验证机制：**3/3 命中**，中位数投票纠正了个别模型偏差。

**说明**
- 真实 hCaptcha 拖拽/滑块题需 live 复现后再校准坐标系与题型判别；点击型已可用，拖拽机制已验证、链路就绪。
- 网关/key 复用现有视觉投票池变量（`.env`），代码零明文。`screenshots_vision/` 已入 `.gitignore`。

## 2026-06-08 — GitHub 注册 + Arkose 验证 agent-captcha 视觉求解

**新增**
- **`register_github.py`**：GitHub 注册主流程。单页表单（邮箱/密码/用户名/国家，只认 `Create account` 不误点 `Continue with Google`），提交触发 **Arkose FunCaptcha**（octocaptcha 包裹），过验证后浏览器登录 Outlook 取 launch code → 建号 → 存 cookie。`--auto` 跑完整流程，无参数为探索模式（填到验证停、保留窗口）。
- **`common/agent_captcha.py`**：Arkose 验证**视觉投票求解器**（不依赖传统打码平台）。
  - **变体自动分派**（按拼图题目文本，不硬编码）：`sequence`（4 图标逐环序列匹配）/ `rotate`（3D 物体朝向匹配）/ `character`（小人踩格，模型分歧大、默认跳过换窗口）。轮数从 "x of N" 解析、候选张数从 `.pip` 进度点数。
  - **多模型并发投票**：`vote_answer()` 让 gemini-3.5-flash / gpt-5.5 / gemini-3.1-pro / claude-opus 并发判断、多数表决；平票优先级 gemini-flash > gpt-5.5 > gemini-pro > opus（实测 claude 在拼图上偏弱，权重最低）。整轮 deadline 55s 防慢模型拖垮，空票自动重试。
  - **图像处理**：候选裁剪放大（`shot_element`）+ 拼成带编号网格（`stitch_options_grid`）+ 本地秒级增强 + 控体积 JPEG（`enhance_local`，避免大图传输超时空票）；可选 gpt-image-2 保真增强（`enhance_image`）。
  - **复盘标注**：每轮落 `screenshots_github/REVIEW_rN.png`，红框=最终选择、彩框=各模型投票，便于人工核对。
  - **协议自适应**：OpenAI 兼容网关走 `/v1/chat/completions`；claude/opus 走 Anthropic 原生 `/v1/messages`（base 以 `/claude` 结尾自动识别），图片 base64 按 JPEG/PNG 头自适应 media_type。
- `config.py` 新增 agent-captcha 配置项（全走 `.env`）：`VISION_API_BASE/KEY`、`VISION_MODEL`、`IMAGE_EDIT_BASE2/KEY2`、`VOTE_ZZ_BASE/KEY`、`VOTE_GPT_KEY`、`VOTE_OPUS_BASE/KEY`、`GEMMA_API_BASE/KEY`；`.env.example` 补齐占位与说明。

**说明**
- Arkose 验证关已实测可通过（sequence 变体 10/10、rotate 5 轮通过）；`character` 变体模型间分歧大，默认遇到即换窗口重试（最多 8 次）赌到易解变体。
- GitHub 对批量 Outlook 邮箱有风控（验证后提示 "This email can't be used"），整套自动化流程完整，邮源需配可用邮箱。
- 网关/key 一律走环境变量（`.env`），代码零明文，符合项目约定。

## 2026-06-07 — chatgpt2api 普通网页号导入

**新增**
- **`export_chatgpt2api.py`**：把注册落下的普通 ChatGPT 网页号聚合成 chatgpt2api（basketikun/chatgpt2api）的批量导入格式。`common/session_export.py:build_chatgpt2api_account` 把网页 session 转成导入对象（只认 `access_token`，**不带 `type:"codex"`**，否则会被对端当 codex 源），注册成功时顺手落 `tokens/chatgpt/c2a-*.json`。
- **`register_chatgpt.py --import-c2a`**：注册成功后用刚抓到的 session 即时 `POST <host>/api/accounts` 把 token 导入 chatgpt2api（默认关）。host/key 取 `config.CHATGPT2API_URL` / `CHATGPT2API_KEY`（走 `.env`），也可 `--c2a-url` / `--c2a-key` 覆盖。单号导入失败只告警，不影响注册成功判定。
- `--import-c2a` 逐层透传：`run_full_flow.py` → `register_three_platforms.py` → `register_chatgpt.py`（只对 chatgpt 平台生效，claude/grok 不受影响）。
- `config.py` 新增 `CHATGPT2API_URL` / `CHATGPT2API_KEY`（默认空，从 `.env` 读）。

**优化**
- `export_chatgpt2api.py` 新增 `import_accounts(host, key, accounts)`（不抛异常版，返回 `(ok, msg)`），供注册脚本逐个号上传时调用；命令行 `--post` 仍用原 `post_accounts`。
- `run_full_flow.py` 顺带提交已有的多轮循环（`--rounds` / `--round-sleep`，支持有限轮数与无限循环）。

**说明**
- 普通网页号无真 `refresh_token`，`access_token` 约 10 天过期后对端无法续期，属预期（codex/OAuth 三件套号仍走 `oauth_codex.py` + CPA/SUB2API）。
- 对端 API 路径是 `/api/accounts`（`/accounts` 是网页 UI），需 `Authorization: Bearer <admin key>`；重复 token 对端按 skipped 幂等处理。

## 2026-06-06 - Gmail Android/Appium 本地注册包

**新增**
- 新增 `gmail_android/` 模块，包含 Gmail Android 注册流程、Appium helper API、`.env` 配置加载、SMS provider 骨架和 Windows 安装脚本。
- 新增 BlueStacks 直接安装/配置脚本：`gmail_android/scripts/install_bluestacks.ps1`，支持配置 ADB、`Pie64_12`、`127.0.0.1:5675`、`900x1600 @ 240dpi`。
- 新增一键安装入口：`gmail_android/scripts/install_all_windows.ps1`，用于 GitHub Release 安装包解压后的环境初始化。
- 新增 Release 构建脚本：`gmail_android/scripts/build_release.ps1`，支持可选附带固定版本 BlueStacks 安装器。
- 新增 `gmail_android/offline/bluestacks/.gitkeep`，预留固定版本 BlueStacks 安装器目录；安装器二进制不进 git，后续随 Release 附件打包。

**优化**
- 根 `.env.example` 增加 Gmail Android/Appium 相关环境变量：`APPIUM_SERVER`、`ANDROID_DEVICE`、`GMAIL_USERNAME_PREFIX`、`ACCEPT_TERMS`、`SMS_PROJECT_ID_GMAIL`、`HERO_SMS_SERVICE_GMAIL` 等。
- 根 `requirements.txt` 增加 `Appium-Python-Client` 和 `selenium`。
- 根 README 增加 Gmail Android 安装包的安装、配置、运行和 Release 打包说明。
- README 补充 GitHub Release 安装包上传流程，覆盖网页上传和 `gh release` 命令两种方式。
- 根 README 前置条件补充 Gmail/谷歌邮箱注册所需的 BlueStacks、Android SDK/ADB、Node/Appium 和 Gmail App。

**安全边界**
- Gmail 手机/SMS/CAPTCHA 和 Google 额外安全验证默认由人工完成；脚本支持 `--resume-after-phone` 续跑。
- `--accept-terms` 仅在操作者明确同意 Google Privacy and Terms 后使用。
- `sms_provider.py` 仅作为后续合规内部接码 provider 的环境变量接口骨架，当前不默认接入 Gmail 安全验证自动化。

## 2026-06-04 — Codex 订阅授权 + 上传 SUB2API / CPA

**新增**
- **`oauth_codex.py`**：账号走 Codex OAuth 换取**带 `refresh_token` 的正式凭据**，一步建到
  **SUB2API**（`type=oauth`）并推 **CPA**，解决网页 session 无 refresh_token、下游过期 401。
- **接码支持 WhatsApp**：遇 OpenAI add-phone 手机验证，用 `--manual-phone` 在浏览器手动填号 +
  输码，**推荐 WhatsApp 可接码号段**（普通虚拟号易被拒）。
- 配套：`activate_plus.py` 激活码开通 Plus / Codex 订阅；`upload_tokens.py` 一键上传到
  CPA / SUB2API / webchat2api。
- 订阅地址 / 激活码全部走环境变量（见 `.env.example`）。

**优化**
- README 补全「Codex 订阅授权 & token 上传」「项目结构 / 模块职责」「典型一条龙用法」，适配多人协作。
- 清理冗余代码，半成品路径标注 WIP。



