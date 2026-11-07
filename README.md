# 云吞插件：Kavita

[Kavita](https://www.kavitareader.com) 是自托管的漫画和电子书阅读服务器。这个插件把它装进云吞：
登录走云吞账号（单点登录），打开就是自己的书架；媒体放在共享文件夹 `media` 里，入库扫描只读访问。

安装后第一次打开，插件会用你的云吞用户名和邮箱在 Kavita 里建好管理员账号并打开自动登录，
你不会看到 Kavita 自己的登录页。管理员密码由云吞生成保管，正常使用用不到；想直接登 Kavita
时可以在插件详情里看说明。

## 说明

- 媒体文件：放进共享文件夹 `media`，在 Kavita 网页里建书库时选择 `/media` 下的目录。
- 图标使用 Kavita 官方标志（原样使用，仅加白色底），来源和许可见 [NOTICE](NOTICE)。
- 开发流程见[插件开发指南](https://github.com/geraldpeng6/wonton-docs/blob/main/develop.md)，
  规则见[插件规范](https://github.com/geraldpeng6/wonton-docs/blob/main/plugin-spec.md)。
