# 图像传输工具

从仓库根目录运行：

```powershell
.\scripts\transfer\upload-images.cmd
.\scripts\transfer\download-images.cmd
```

默认路径：

| 方向 | 本地 | 树莓派 |
| --- | --- | --- |
| 上传 | `data/Image` | `/home/r/Raspberry/Image` |
| 下载 | `data/Image/raspberry_image` | `/home/r/Raspberry/Image` |

`.cmd` 是绕过本机 PowerShell 执行策略的启动器。SSH 主机记录保存在仓库根目录的 `.state/ssh`，该目录不会被 Git 跟踪。
