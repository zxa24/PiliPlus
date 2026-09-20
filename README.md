<div align="center">
    <img width="200" height="200" src="assets/images/logo/logo.png">
</div>



<div align="center">
    <h1>LibrePili</h1>
<div align="center">
    
![GitHub repo size](https://img.shields.io/github/repo-size/zxa24/PiliPlus) 
![GitHub Repo stars](https://img.shields.io/github/stars/zxa24/PiliPlus) 
![GitHub all releases](https://img.shields.io/github/downloads/zxa24/PiliPlus/total) 
![License](https://img.shields.io/badge/license-GPL--3.0-blue) 
</div>
    <p>使用Flutter开发的BiliBili第三方客户端，注重隐私</p>
    <p><a href="https://github.com/bggRGjQaUbCoE/PiliPlus">PiliPlus</a> 的分支：默认无痕，登录是可选项</p>
    
<img src="assets/screenshots/510shots_so.png" width="32%" alt="home" />
<img src="assets/screenshots/174shots_so.png" width="32%" alt="home" />
<img src="assets/screenshots/850shots_so.png" width="32%" alt="home" />
<br/>
<img src="assets/screenshots/main_screen.png" width="96%" alt="home" />
<br/>
</div>


<br/>

## LibrePili 与上游 PiliPlus 的区别

LibrePili 是 [bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 的分支，
改动集中在“账号什么时候被带上”这一件事上。上游的功能保留（见下文各节），以下是本分支新增或改写的部分。

### 默认无痕，登录是可选项

- **默认不登录**。全部请求匿名发出，匿名请求每次启动换一个设备标识（buvid），无法跨启动关联。
- **登录模式是显式开关**，默认关闭。关闭时，即使本机存有账号也处于休眠状态，一个请求都不带。
- 完成一次登录即视为开启登录模式；退出后账号被标记为“已失效”而**不是**静默删除，由用户决定重新登录还是移除。

### 按请求绑定账号（`LoginPolicy`）

开启登录模式后，账号也**只**附加到需要它的请求上，见
[`lib/utils/accounts/login_policy.dart`](lib/utils/accounts/login_policy.dart)：

- 带账号：本人私有数据的读取（收藏、历史、消息、关注列表…）、带 csrf 的写操作、
  播放地址（高画质需要账号）、登录流程本身；
- 首页「推荐」流及其「不感兴趣」反馈绑定到**推荐角色**的账号（该角色也可以留空 = 匿名）；
- 其余一律匿名发出：搜索、首页其他 tab、视频信息、评论、UP 主空间等，
  因此这些浏览行为无法与账号关联。

多账号可按角色分配（推荐 / 视频 / 直播 / 动态 / 消息…），互不关联。

### 无账号也能用的本地关注 / 收藏

本地关注和本地收藏夹只存在本机（Hive），不经过服务器，登录与否都可用；
它们是**没有账号时的唯一副本**，导入/重置前会先存快照。
见 [`lib/services/local_library.dart`](lib/services/local_library.dart)。

### 离线 / 本地播放

- 下载导出为**每个视频一个文件夹、一个完整 mp4**，旁边放弹幕（XML/ASS）、字幕（SRT）和评论（JSON）；
- 内置本地播放器可直接打开下载目录、任意视频文件或（Android）用系统选择器挑选的文档，
  连带读出旁边的弹幕/字幕/评论；
- 离线/本地播放**不上报**任何观看历史。

### 设置快照与撤回

导入设置 / WebDAV 恢复 / 重置可导出的设置之前，会先把当前设置与本地关注收藏存成快照，
可用「恢复到导入前」撤回。「重置所有数据（含登录信息）」按其字面意思执行：
不留快照，同时清除日志与临时镜像，**不可撤回**。

<br/>

## 适配平台

- [x] Android
- [x] iOS
- [x] Pad
- [x] Windows
- [x] Linux

## refactor

- [ ] gRPC [wip]
- [x] 用户界面
- [x] 其他

## feat

- [x] 编辑动态
- [x] DLNA 投屏
- [x] 离线缓存/播放
- [x] 移动端支持点击弹幕悬停，点赞、复制、举报 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 播放音频
- [x] 跳过番剧片头/片尾
- [x] 安卓端 `loudnorm` 适配 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] Win/Mac 支持极验、短信登录 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 视频截取动图 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] AI 原声翻译
- [x] SuperChat
- [x] 播放课堂视频
- [x] 发起投票
- [x] 发布动态/评论支持`富文本编辑`/`表情显示`/`@用户`
- [x] 修改消息设置
- [x] 修改聊天设置
- [x] 展示折叠消息
- [x] 查看用户图文
- [x] 动态话题
- [x] 直播分区
- [x] 分享`视频`/`番剧`/`动态`/`专栏`/`直播`至消息
- [x] 创建/修改/删除关注分组
- [x] 移除粉丝
- [x] 直播弹幕发送表情
- [x] 收藏夹排序
- [x] 稍后再看 ~~`未看`~~ / `未看完` / ~~`已看完`~~ 分类
- [x] WebDAV 备份/恢复设置
- [x] 保存评论/动态
- [x] 高级弹幕 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 取消/置顶评论
- [x] 记笔记
- [x] 多账号支持 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 屏蔽带货动态/评论
- [x] 互动视频
- [x] 发评/动态反诈
- [x] 高能进度条
- [x] 滑动跳转预览视频缩略图
- [x] Live Photo
- [x] 复制/移动/排序收藏夹/稍后再看视频
- [x] 超分辨率
- [x] 合并弹幕
- [x] 会员彩色弹幕
- [x] 播放全部/继续播放/倒序播放
- [x] Cookie登录
- [x] 显示视频分段信息
- [x] 调节字幕大小
- [x] 调节全屏弹幕大小
- [x] 收藏夹/稍后再看多选删除
- [x] 搜索用户动态
- [x] 直播弹幕
- [x] 修改头像/用户名/签名/性别/生日
- [x] 创建/编辑/删除收藏夹
- [x] 评论楼中楼查看对话
- [x] 评论楼中楼定位点击查看的评论
- [x] 评论楼中楼按热度/时间排序
- [x] 评论点踩
- [x] 私信发图
- [x] 投币动画
- [x] 取消/追番，更新追番状态
- [x] 取消/订阅合集
- [x] SponsorBlock
- [x] 显示视频完整合集
- [x] 三连动画
- [x] 番剧三连
- [x] 带图评论
- [x] 视频TAG
- [x] 筛选搜索
- [x] 转发动态
- [x] 合集图片
- [x] 删除/置顶/撤回私信
- [x] 举报用户/评论/视频/动态
- [x] 删除/发布/置顶文本/图片动态
- [x] 其他

## opt

- [x] 专栏界面
- [x] 私信界面
- [x] 收藏面板
- [x] PIP
- [x] 视频封面
- [x] 回复界面
- [x] 系统通知
- [x] 评论显示
- [x] 亮度调节
- [x] 视频播放
- [x] 视频staff
- [x] 防止bottomsheet遮挡全屏视频
- [x] 其他

## fix

- [x] 番剧分集点赞/投币/收藏
- [x] bugs

<br/>

## 功能

- [x] 推荐视频列表(app端)
- [x] 最热视频列表
- [x] 热门直播
- [x] 番剧列表
- [x] 屏蔽黑名单内用户视频
- [x] 默认无痕（不登录，全部请求匿名）
- [x] 登录模式为可选开关，开启后仅在必要处附加账号（见上文 `LoginPolicy`）
- [x] 本地关注 / 本地收藏夹（无需账号）

- [x] 用户相关
  - [x] 粉丝、关注用户、拉黑用户查看
  - [x] 用户主页查看
  - [x] 关注/取关用户
  - [x] 离线缓存
  - [x] 稍后再看
  - [x] 观看记录
  - [x] 我的收藏
  - [x] 站内私信
  
- [x] 动态相关
  - [x] 全部、投稿、番剧分类查看
  - [x] 动态评论查看
  - [x] 动态评论回复功能

- [x] 视频播放相关
  - [x] 双击快进/快退
  - [x] 双击播放/暂停
  - [x] 垂直方向调节亮度/音量
  - [x] 垂直方向上滑全屏、下滑退出全屏
  - [x] 水平方向手势快进/快退
  - [x] 全屏方向设置
  - [x] 倍速选择/长按2倍速
  - [x] 硬件加速（视机型而定）
  - [x] 画质选择（高清画质未解锁）
  - [x] 音质选择（视视频而定）
  - [x] 解码格式选择（视视频而定）
  - [x] 弹幕
  - [x] 字幕
  - [x] 记忆播放
  - [x] 视频比例：高度/宽度适应、填充、包含等
     
- [x] 搜索相关
  - [x] 热搜
  - [x] 搜索历史
  - [x] 默认搜索词
  - [x] 投稿、番剧、直播间、用户搜索
  - [x] 视频搜索排序、按时长筛选
    
- [x] 视频详情页相关
  - [x] 视频选集(分p)切换
  - [x] 点赞、投币、收藏/取消收藏
  - [x] 相关视频查看
  - [x] 评论用户身份标识
  - [x] 评论(排序)查看、二楼评论查看
  - [x] 主楼、二楼评论回复功能
  - [x] 评论点赞
  - [x] 评论笔记图片查看、保存

- [x] 设置相关
  - [x] 画质、音质、解码方式预设      
  - [x] 图片质量设定
  - [x] 主题模式：亮色/暗色/跟随系统
  - [x] 震动反馈(可选)
  - [x] 高帧率
  - [x] 自动全屏
  - [x] 横屏适配
- [ ] 等等

<br/>

## 下载

可以通过右侧 release 进行下载，或拉取代码到本地自行编译。
上游 PiliPlus 的 release 不适用于本分支。

<br/>

## 声明

此项目（LibrePili）是个人为了兴趣而开发，仅用于学习和测试，请于下载后24小时内删除。
所用API皆从官方网站收集，不提供任何破解内容。

### 许可与修改说明（GPL-3.0）

本项目以 GPL-3.0 授权，源自 [bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)。
相对上游的主要修改：默认无痕并把登录改为可选开关、按请求绑定账号（`LoginPolicy`）、
无账号的本地关注/收藏、下载导出为单个 mp4 + 旁挂弹幕/字幕/评论、本地/离线播放器（不上报历史）、
设置快照与撤回。详见上文「LibrePili 与上游 PiliPlus 的区别」及提交历史。

上游及其前身：
- 上游：[bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)
- [orz12/PiliPalaX](https://github.com/orz12/PiliPalaX)
- 原作者：[guozhigq/pilipala](https://github.com/guozhigq/pilipala)

感谢原作者们的开源精神。感谢使用


<br/>

## 致谢

- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)
- [flutter_meedu_videoplayer](https://github.com/zezo357/flutter_meedu_videoplayer)
- [media-kit](https://github.com/media-kit/media-kit)
- [dio](https://pub.dev/packages/dio)
- 等等

<br/>
<br/>
<br/>

## Star History

<a href="https://star-history.dera.page/#zxa24/PiliPlus&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://star-history.dera.page/svg?repos=zxa24/PiliPlus&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://star-history.dera.page/svg?repos=zxa24/PiliPlus&type=Date" />
   <img alt="Star History Chart" src="https://star-history.dera.page/svg?repos=zxa24/PiliPlus&type=Date" />
 </picture>
</a>
