# 云吞插件：Kavita

[Kavita](https://www.kavitareader.com) 是自托管的漫画和电子书阅读服务器。这个插件把它装进云吞：
登录走云吞账号（单点登录），打开就是自己的书架；媒体放在共享文件夹 `media` 里，入库扫描只读访问。

安装后第一次打开，插件会用你的云吞用户名和邮箱在 Kavita 里建好管理员账号并打开自动登录，
你不会看到 Kavita 自己的登录页。管理员密码由云吞生成保管，正常使用用不到；想直接登 Kavita
时可以在插件详情里看说明。

## 说明

- 媒体文件：放进共享文件夹 `media`，在 Kavita 网页里建书库时选择 `/media` 下的目录。

- 换核心时容器会重建；浏览器里的单点登录现在走不完回调——ASP.NET 用 `form_post`，回调是跨站 POST，网关的会话 Cookie 是 `SameSite=Lax`，POST 带不上登录状态，网关回 401。修好前打不开。
- 图标使用 Kavita 官方标志（原样使用，仅加白色底），来源和许可见 [NOTICE](NOTICE)。
- 开发流程见[插件开发指南](https://github.com/wontonapp/wonton-docs/blob/main/develop.md)，
  规则见[插件规范](https://github.com/wontonapp/wonton-docs/blob/main/plugin-spec.md)。
