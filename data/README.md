# 本地数据目录

`data/Image` 保存从树莓派下载或准备上传的图像。该目录中的实际内容已被 `.gitignore` 排除，不会推送到 GitHub。

默认传输路径：

```text
上传：data/Image -> /home/r/Raspberry/Image
下载：/home/r/Raspberry/Image -> data/Image/raspberry_image
```

请勿在此提交 RAW、PNG/JPEG、标定数据、生产权重或包含敏感信息的日志。如需共享小型固定测试样本，应单独建立 `tests/fixtures`，记录来源、许可、尺寸和哈希。
