# FlexSim MCP

通过标准 MCP stdio 协议在 Windows 上操作本机 FlexSim：打开模型、运行 FlexScript、保存模型和读取 CSV 仿真结果。支持 Codex 插件安装，也可作为独立 MCP 服务使用。

本仓库采用 [MIT 许可证](LICENSE) 开源，允许使用、修改和分发，须保留版权与许可声明。FlexSim 本体及其他依赖遵循各自许可。DSH 独立版本位于 [dsh-flexsim-mcp](https://github.com/w2cemm/dsh-flexsim-mcp)。

## 环境

- Windows 10/11，Python 3.10+（标准库，无 pip 依赖）。
- 单独安装、合法授权的 FlexSim；当前坐标配置在 FlexSim 2023 上验证。
- Windows PowerShell 5.1 和 elevated companion。普通权限 MCP 服务通过本机文件队列请求 companion 操作管理员权限的 FlexSim。
- Codex 插件安装需要带 `codex plugin` 命令的 Codex CLI，`python` 必须在客户端 PATH 中。

本仓库不包含 FlexSim 软件、授权文件、用户模型或仿真数据，也不隶属于 FlexSim 官方。

## 在 Codex 中本地安装

克隆仓库后，在仓库根目录执行：

```powershell
python scripts/install_local.py --dry-run
python scripts/install_local.py --companion "C:\path\to\existing\companion"
```

没有现成 companion 时可省略 `--companion`，使用仓库内的 companion。注册插件不会启动或安装管理员计划任务。

安装脚本调用受支持的 `codex plugin marketplace add` 与 `codex plugin add` 命令，登记 `flexsim-mcp@flexsim-local`。个人设置写入 `%LOCALAPPDATA%\FlexSimMCP\settings.json`，安装版本、来源、时间、CLI 返回结果及文件 SHA-256 写入同目录的 `installation.json`。重复安装会先备份已有个人设置。

重启 Codex 或新建聊天后检查插件及工具。原先已经配置 `[mcp_servers.flexsim]` 的用户可能同时看到独立服务和插件内服务；两者连接同一个 companion 时使用同一 runtime 文件锁。确认新插件可用后，可自行停用旧独立服务。

也可直接注册本仓库：

```powershell
codex plugin marketplace add .
codex plugin add flexsim-mcp@flexsim-local
codex plugin list --json
```

## 首次安装 companion

`companion/` 包含原有 Windows 提权桥接代码。复用已有 companion 时跳过这一节。

先审阅 `companion/install.ps1` 与 `worker.ps1`，再手动运行 `companion/install.cmd` 并接受 UAC。它会设置队列 ACL，注册当前用户的 `DSH_ElevCompanion` 管理员登录计划任务，并做自检。该任务名与原 DSH companion 相同：已有该任务时应复用现有目录，避免替换其任务路径。

`companion/start.cmd` 启动已登记的任务；`companion/uninstall.ps1` 移除该任务。插件登记与 companion 的计划任务安装是分别执行的步骤。仓库内的脚本不会在插件启用时自动运行。worker 还保留原 companion 的通用桌面动作及可选 windows-mcp 支持，FlexSim MCP 仅调用其中所需动作；独立 FlexSim 功能不要求安装 windows-mcp。

worker 的 `$ExeAllow` 默认使用 FlexSim 2023 安装路径。使用其他版本时，应同时审阅/调整该白名单和 `FLEXSIM_EXE`；只设置环境变量不能绕过 worker 白名单。

## MCP 配置

`.codex-plugin/plugin.json` 是插件清单，`.mcp.json` 是随插件分发的配置。`${PLUGIN_ROOT}` 由客户端替换成插件安装目录。

独立 MCP 客户端使用绝对路径：

```json
{
  "mcpServers": {
    "flexsim": {
      "command": "python",
      "args": ["C:/path/to/flexsim-mcp/scripts/launch.py"],
      "env": {
        "FLEXSIM_COMPANION_DIR": "C:/path/to/companion"
      }
    }
  }
}
```

Codex 独立服务的 TOML 示例：

```toml
[mcp_servers.flexsim]
command = "python"
args = ["C:/path/to/flexsim-mcp/scripts/launch.py"]
startup_timeout_sec = 60
tool_timeout_sec = 180
```

启动器先读取个人 `settings.json`；环境变量优先。支持 `FLEXSIM_COMPANION_DIR`、`FLEXSIM_EXE`、`FLEXSIM_MCP_RUNTIME_DIR`、`FLEXSIM_MCP_LOG`。可用 `FLEXSIM_MCP_SETTINGS` 指向另一份个人设置。配置不需要 API 密钥。直接运行 `flexsim-mcp/server.py` 时只读取环境变量，不读取个人设置。

## 工具

| 工具 | 用途 |
|---|---|
| `flexsim_status` | 检查 companion 心跳、FlexSim 窗口 |
| `flexsim_open` | 打开 FlexSim 或指定 `.fsm` 模型 |
| `flexsim_set_script` | 写入脚本，不运行 |
| `flexsim_run_script` | 运行 UTF-8 文件或内联 FlexScript，验证本次唯一完成标记 |
| `flexsim_console` | 读取可访问的诊断面板，可能无法读取 `print()` 输出 |
| `flexsim_save` | 保存绝对 `.fsm` 路径，默认拒绝覆盖；显式覆盖先备份，再验证稳定文件与 SHA-256 |
| `flexsim_stats` | 读取模型导出的 CSV |
| `flexsim_close` | 关闭 FlexSim 进程，应先保存模型 |

`verified=true` 表示脚本执行到结尾。`go()` 启动的异步仿真需要另外检查停止状态或结果。编译失败、提前 `return`、中断或超时不会被报告为已确认完成，也不会自动重试已有副作用的脚本。

## 坐标校准与限制

`flexsim-mcp/config.json` 存储脚本工具栏和运行按钮的相对偏移。FlexSim 版本、窗口布局或 DPI 改变后须重新校准。输入编辑器通过 Scintilla 元数据识别，识别不明确时拒绝写入。

输出建议由模型写入 CSV，再用 `flexsim_stats` 读取。运行凭据、临时 UTF-8 脚本及保存清单存放 runtime 目录，用户业务 CSV 仍由模型决定位置。运行和保存通过文件锁串行化。

## 验证与发布范围

```powershell
python -m unittest discover -s flexsim-mcp -p "test_*.py" -v
python -m unittest discover -s tests -p "test_*.py" -v
```

现有可靠性回归覆盖输入识别、中文脚本、完成标记、覆盖保护和保存校验。打包测试额外验证路径、stdio 握手、工具列表和配置错误处理。GUI 实际运行依赖本机 companion、FlexSim 和坐标校准。

发布到 GitHub 是源码分发，不等于提交到 OpenAI 公共插件目录。格式依据 [官方插件打包说明](https://developers.openai.com/plugins/build/plugins) 与 [本地 MCP 配置说明](https://developers.openai.com/plugins/deploy/desktop-only)。当前使用官方仍支持的 Codex 兼容格式。
