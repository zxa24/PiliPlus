import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/avatars.dart';
import 'package:PiliPlus/common/widgets/image_viewer/hero.dart';
import 'package:PiliPlus/common/widgets/pendant_avatar.dart';
import 'package:PiliPlus/common/widgets/scroll_physics.dart'
    show tabBarScrollPhysics;
import 'package:PiliPlus/common/widgets/space/space_header.dart';
import 'package:PiliPlus/models/common/image_preview_type.dart';
import 'package:PiliPlus/models/common/member/user_info_type.dart';
import 'package:PiliPlus/models/model_owner.dart';
import 'package:PiliPlus/models_new/space/space/card.dart';
import 'package:PiliPlus/models_new/space/space/elec.dart';
import 'package:PiliPlus/models_new/space/space/followings_followed_upper.dart';
import 'package:PiliPlus/models_new/space/space/images.dart';
import 'package:PiliPlus/models_new/space/space/live.dart';
import 'package:PiliPlus/models_new/space/space/pr_info.dart';
import 'package:PiliPlus/models_new/space/space/top.dart';
import 'package:PiliPlus/pages/fan/view.dart';
import 'package:PiliPlus/pages/follow/view.dart';
import 'package:PiliPlus/pages/follow_type/followed/view.dart';
import 'package:PiliPlus/pages/member/widget/medal_widget.dart';
import 'package:PiliPlus/pages/member_guard/view.dart';
import 'package:PiliPlus/pages/member_upower_rank/view.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/bili_colors.dart';
import 'package:PiliPlus/utils/bili_utils.dart';
import 'package:PiliPlus/utils/color_utils.dart';
import 'package:PiliPlus/utils/extension/context_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class UserInfoCard extends StatelessWidget {
  const UserInfoCard({
    super.key,
    required this.isOwner,
    required this.card,
    required this.images,
    required this.relation,
    required this.onFollow,
    this.live,
    this.silence,
    required this.headerControllerBuilder,
    required this.showLiveMedalWall,
    required this.charges,
    required this.chargeCount,
    required this.guards,
    required this.guardCount,
  });

  final bool isOwner;
  final int relation;
  final SpaceCard card;
  final SpaceImages images;
  final VoidCallback onFollow;
  final Live? live;
  final int? silence;
  final ValueGetter<PageController> headerControllerBuilder;
  final VoidCallback showLiveMedalWall;
  final List<ElecItem>? charges;
  final Object? chargeCount;
  final List<Owner>? guards;
  final Object? guardCount;

  /// LibrePili: the card's arrangement and the type of its shared parts
  /// are [SpaceHeaderCard]'s, which the YouTube channel header uses too.
  /// What is passed in here is bilibili's own: level, vip, medal,
  /// verification, charge and guard, followed-up, ban, promotion.
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isLight = colorScheme.isLight;
    final width = context.width;
    final imgUrls = images.collectionTopSimple?.top?.imgUrls;
    return SpaceHeaderCard(
      banner: imgUrls != null && imgUrls.isNotEmpty
          ? _buildCollectionHeader(context, colorScheme, isLight, imgUrls, width)
          : SpaceBanner(
              url: (isLight
                      ? images.imgUrl
                      : images.nightImgurl.isNullOrEmpty
                      ? images.imgUrl
                      : images.nightImgurl)
                  .http2https,
            ),
      avatar: _buildAvatar(colorScheme),
      left: (isPortrait) =>
          _buildLeft(context, colorScheme, isLight, isPortrait),
      actions: _buildRight(colorScheme),
      bottom: card.prInfo?.content?.isNotEmpty ?? false
          ? buildPrInfo(context, colorScheme, isLight, card.prInfo!)
          : null,
    );
  }

  SpaceCount _count(UserInfoType type) {
    int? count;
    VoidCallback? onTap;
    switch (type) {
      case UserInfoType.fan:
        count = card.fans;
        onTap = () => FansPage.toFansPage(
          mid: card.mid,
          name: card.name,
        );
      case UserInfoType.follow:
        count = card.attention;
        onTap = () => FollowPage.toFollowPage(
          mid: card.mid,
          name: card.name,
        );
      case UserInfoType.like:
        count = card.likes?.likeNum;
    }
    return SpaceCount(
      value: NumUtils.numFormat(count),
      label: type.title,
      alignment: type.alignment,
      onTap: onTap,
      detail: '${type.title}: $count',
    );
  }

  List<Widget> _buildLeft(
    BuildContext context,
    ColorScheme colorScheme,
    bool isLight,
    bool isPortrait,
  ) {
    return [
      _buildName(context, colorScheme),
      if (card.officialVerify?.desc?.isNotEmpty ?? false)
        _buildVerify(colorScheme),
      if (card.sign?.isNotEmpty ?? false) _buildSign(),
      ?_buildChargeAndGuard(colorScheme, isPortrait),
      if (card.followingsFollowedUpper?.items?.isNotEmpty ?? false)
        _buildFollowedUp(colorScheme, card.followingsFollowedUpper!),
      _buildExtraInfo(colorScheme),
      if (silence == 1) _buildBanWidget(colorScheme, isLight),
    ];
  }

  Widget _buildName(BuildContext context, ColorScheme colorScheme) {
    Widget? liveMedal;
    if (card.liveFansWearing?.detailV2 case final detailV2?) {
      Color? nameColor;
      Color? backgroundColor;
      try {
        nameColor = ColourUtils.parseColor(detailV2.medalColorName!);
        backgroundColor = ColourUtils.parseColor(detailV2.medalColor!);
      } catch (e, s) {
        if (kDebugMode) {
          Utils.reportError(e, s);
        }
      }
      try {
        liveMedal = GestureDetector(
          onTap: showLiveMedalWall,
          child: MedalWidget(
            medalName: detailV2.medalName!,
            level: detailV2.level!,
            backgroundColor: backgroundColor ?? colorScheme.secondaryContainer,
            nameColor: nameColor ?? colorScheme.onSecondaryContainer,
          ),
        );
      } catch (e, s) {
        if (kDebugMode) {
          Utils.reportError(e, s);
        }
      }
    }
    return SpaceName(
      name: card.name!,
      onTap: () => Utils.copyText(card.name!),
      color: (card.vip?.status ?? -1) > 0 && card.vip?.type == 2
          ? colorScheme.vipColor
          : null,
      trailing: [
          BiliUtils.levelPicture(
            card.levelInfo!.currentLevel!,
            isSeniorMember: card.levelInfo?.identity == 2,
            height: 11,
          ),
          if (card.vip?.status == 1)
            Container(
              padding: const .symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: Style.mdRadius,
                color: colorScheme.vipColor,
              ),
              child: Text(
                card.vip?.label?.text ?? '大会员',
                strutStyle: const StrutStyle(
                  height: 1,
                  leading: 0,
                  fontSize: 10,
                  fontWeight: .bold,
                ),
                style: const TextStyle(
                  height: 1,
                  fontSize: 10,
                  color: Colors.white,
                  fontWeight: .bold,
                ),
              ),
            ),
          // if (card.nameplate?.imageSmall?.isNotEmpty ?? false)
          //   CachedNetworkImage(
          //     imageUrl: ImageUtils.thumbnailUrl(card.nameplate!.imageSmall!),
          //     height: 20,
          //     placeholder: (context, url) {
          //       return const SizedBox.shrink();
          //     },
          //   ),
          ?liveMedal,
      ],
    );
  }

  Widget _buildVerify(ColorScheme colorScheme) {
    return Container(
      margin: const .only(left: 20, top: 8, right: 20),
      padding: const .symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: const .all(.circular(12)),
        color: colorScheme.onInverseSurface,
      ),
      child: Text.rich(
        TextSpan(
          children: [
            if (card.officialVerify?.spliceTitle?.isNotEmpty ?? false) ...[
              WidgetSpan(
                alignment: .middle,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: .circle,
                    color: colorScheme.surface,
                  ),
                  child: card.officialVerify?.type == 0
                      ? const Icon(
                          Icons.offline_bolt,
                          color: BiliColors.yellow,
                          size: 18,
                        )
                      : const Icon(
                          Icons.offline_bolt,
                          color: Colors.lightBlueAccent,
                          size: 18,
                        ),
                ),
              ),
              const TextSpan(text: ' '),
            ],
            TextSpan(
              text: card.officialVerify!.spliceTitle!,
              style: TextStyle(
                fontSize: 12,
                fontWeight: .bold,
                color: colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSign() => SpaceSign(card.sign!);

  Widget _buildExtraInfo(ColorScheme colorScheme) {
    return SpaceExtraLine(
        children: [
          GestureDetector(
            onTap: () => Utils.copyText(card.mid.toString()),
            child: Text(
              'UID: ${card.mid}',
              style: SpaceExtraLine.style(colorScheme),
            ),
          ),
          ...?card.spaceTag?.map(
            (item) {
              final hasUri = item.uri?.isNotEmpty ?? false;
              final child = Text(
                item.title ?? '',
                style: SpaceExtraLine.style(colorScheme, link: hasUri),
              );
              if (hasUri) {
                return GestureDetector(
                  onTap: () => PiliScheme.routePushFromUrl(item.uri!),
                  child: child,
                );
              }
              return child;
            },
          ),
        ],
    );
  }

  Widget _buildBanWidget(ColorScheme colorScheme, bool isLight) {
    return Container(
      width: .infinity,
      decoration: BoxDecoration(
        borderRadius: const .all(.circular(6)),
        color: isLight ? colorScheme.errorContainer : colorScheme.error,
      ),
      margin: const .only(left: 20, top: 8, right: 20),
      padding: const .symmetric(horizontal: 8, vertical: 4),
      child: Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              alignment: .middle,
              child: Icon(
                Icons.info,
                size: 17,
                color: isLight
                    ? colorScheme.onErrorContainer
                    : colorScheme.onError,
              ),
            ),
            TextSpan(
              text: ' 该账号封禁中',
              style: TextStyle(
                color: isLight
                    ? colorScheme.onErrorContainer
                    : colorScheme.onError,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRight(ColorScheme colorScheme) => SpaceActions(
    counts: UserInfoType.values.map(_count).toList(),
    leading: [
      // LibrePili: messaging needs login
      if (!isOwner && Accounts.main.isLogin)
        IconButton.outlined(
          onPressed: () {
            if (Accounts.main.isLogin) {
              int mid = int.parse(card.mid!);
              Get.toNamed(
                '/whisperDetail',
                arguments: {
                  'talkerId': mid,
                  'name': card.name,
                  'face': card.face,
                  'mid': mid,
                  'isLive': live?.liveStatus == 1,
                },
              );
            }
          },
          icon: const Icon(Icons.mail_outline, size: 21),
          style: ButtonStyle(
            side: WidgetStatePropertyAll(
              BorderSide(
                width: 1.0,
                color: colorScheme.outline.withValues(alpha: 0.3),
              ),
            ),
            padding: const WidgetStatePropertyAll(.zero),
            tapTargetSize: .shrinkWrap,
            visualDensity: .compact,
          ),
        ),
    ],
    follow: SpaceFollowButton(
      onPressed: !isOwner && relation == -1 ? null : onFollow,
      followed: relation != 0,
      icon: relation == -1
          ? Icons.block
          : relation != 0 && relation != 128
          ? Icons.sort
          : null,
      label: isOwner
          ? '编辑资料'
          : switch (relation) {
              0 || -1 => '关注',
              1 => '悄悄关注',
              2 => '已关注',
              // 3 => '回关',
              4 || 6 => '已互关',
              128 => '移除黑名单',
              -10 => '特别关注', // 该状态码并不是官方状态码
              _ => relation.toString(),
            },
    ),
  );

  Widget _buildAvatar(ColorScheme scheme) {
    final pendant = card.pendant?.image;
    Widget child = PendantAvatar(
      card.face,
      size: kAvatarSize,
      pendentOffset: 12,
      badgeSize: 20,
      officialType: card.officialVerify?.type,
      vipStatus: card.vip?.status,
      pendantImage: pendant,
      roomId: live?.liveStatus == 1 ? live!.roomid : null,
      onTap: () => PageUtils.imageView(
        tag: hashCode.toString(),
        imgList: [SourceModel(url: card.face.http2https)],
      ),
    );
    if (pendant == null || pendant.isEmpty) {
      child = SpaceAvatarRing(child: child);
    }
    return fromHero(
      tag: '${card.face}$hashCode',
      child: child,
    );
  }

  Widget _buildCollectionHeader(
    BuildContext context,
    ColorScheme scheme,
    bool isLight,
    List<TopImage> imgUrls,
    double width,
  ) {
    if (imgUrls.length == 1) {
      final img = imgUrls.first;
      final title = img.title;
      Widget child = SpaceBanner(
        url: img.header,
        filter: false,
        fullCover: img.fullCover,
        alignment: Alignment(0.0, img.dy),
      );
      if (title != null) {
        return Stack(
          clipBehavior: .none,
          children: [
            child,
            Positioned(
              right: 0,
              bottom: 0,
              child: _headerWrapper(_headerTitle(title)),
            ),
          ],
        );
      }
      return child;
    }
    final controller = headerControllerBuilder();
    final memCacheWidth = width.cacheSize(context);
    return GestureDetector(
      behavior: .opaque,
      onTap: () => PageUtils.imageView(
        initialPage: controller.page?.round() ?? 0,
        imgList: imgUrls.map((e) => SourceModel(url: e.fullCover)).toList(),
        onPageChanged: controller.jumpToPage,
      ),
      child: Stack(
        clipBehavior: .none,
        children: [
          SizedBox(
            width: .infinity,
            height: kHeaderHeight,
            child: PageView.builder(
              controller: controller,
              itemCount: imgUrls.length,
              physics: tabBarScrollPhysics,
              itemBuilder: (context, index) {
                final img = imgUrls[index];
                return fromHero(
                  tag: img.fullCover,
                  child: CachedNetworkImage(
                    fit: .cover,
                    alignment: Alignment(0.0, img.dy),
                    height: kHeaderHeight,
                    width: width,
                    memCacheWidth: memCacheWidth,
                    imageUrl: ImageUtils.thumbnailUrl(img.header),
                    fadeInDuration: const Duration(milliseconds: 120),
                    fadeOutDuration: const Duration(milliseconds: 120),
                    placeholder: (_, _) =>
                        const SizedBox(width: .infinity, height: kHeaderHeight),
                  ),
                );
              },
            ),
          ),
          Positioned(
            right: 0,
            bottom: 3.5,
            child: _headerWrapper(
              HeaderTitle(
                images: imgUrls,
                pageController: controller,
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: HeaderIndicator(
              length: imgUrls.length,
              pageController: controller,
            ),
          ),
        ],
      ),
    );
  }

  Widget buildPrInfo(
    BuildContext context,
    ColorScheme colorScheme,
    bool isLight,
    SpacePrInfo prInfo,
  ) {
    final textColor = ColourUtils.parseColor(
      isLight ? prInfo.textColor : prInfo.textColorNight,
    );
    String? icon = !isLight && prInfo.iconNight?.isNotEmpty == true
        ? prInfo.iconNight
        : prInfo.icon?.isNotEmpty == true
        ? prInfo.icon
        : null;

    Widget child = Container(
      margin: const .only(top: 8),
      padding: const .symmetric(horizontal: 16, vertical: 10),
      color: ColourUtils.parseColor(
        isLight ? prInfo.bgColor : prInfo.bgColorNight,
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            CachedNetworkImage(
              height: 20,
              memCacheHeight: 20.cacheSize(context),
              imageUrl: ImageUtils.thumbnailUrl(icon),
              placeholder: (_, _) => const SizedBox.shrink(),
              fadeInDuration: .zero,
              fadeOutDuration: .zero,
            ),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Text(
              card.prInfo!.content!,
              style: TextStyle(fontSize: 13, color: textColor),
            ),
          ),
          if (prInfo.url?.isNotEmpty ?? false) ...[
            const SizedBox(width: 10),
            Icon(
              Icons.keyboard_arrow_right,
              color: textColor,
            ),
          ],
        ],
      ),
    );
    if (prInfo.url?.isNotEmpty ?? false) {
      return GestureDetector(
        onTap: () => PageUtils.handleWebview(prInfo.url!),
        child: child,
      );
    }
    return child;
  }

  Widget _buildChargeItem(
    ColorScheme colorScheme,
    List<Owner>? list,
    Object? count,
    String desc,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: .min,
        children: [
          avatars(
            gap: 10,
            colorScheme: colorScheme,
            users: list!.take(3),
          ),
          const SizedBox(width: 4),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: NumUtils.numFormat(count),
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                TextSpan(
                  text: desc,
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.keyboard_arrow_right,
            size: 20,
            color: colorScheme.outline,
          ),
        ],
      ),
    );
  }

  Widget? _buildChargeAndGuard(ColorScheme colorScheme, bool isPortrait) {
    final children = [
      if (charges?.isNotEmpty ?? false)
        _buildChargeItem(
          colorScheme,
          charges,
          chargeCount,
          '人为TA充电',
          () => UpowerRankPage.toUpowerRank(
            mid: card.mid!,
            name: card.name!,
            count: chargeCount,
          ),
        ),
      if (guards?.isNotEmpty ?? false)
        _buildChargeItem(
          colorScheme,
          guards,
          guardCount,
          '人加入大航海',
          () => MemberGuard.toMemberGuard(
            mid: card.mid!,
            name: card.name!,
            count: guardCount,
          ),
        ),
    ];
    if (children.isNotEmpty) {
      Widget child;
      if (children.length == 1) {
        child = children.first;
      } else {
        child = isPortrait
            ? Row(mainAxisAlignment: .spaceBetween, children: children)
            : Wrap(spacing: 10, runSpacing: 6, children: children);
      }
      return Padding(
        padding: const .only(left: 20, right: 20, top: 6),
        child: child,
      );
    }
    return null;
  }

  Widget _buildFollowedUp(
    ColorScheme colorScheme,
    FollowingsFollowedUpper item,
  ) {
    var list = item.items!;
    final flag = list.length > 3;
    if (flag) list = list.sublist(0, 3);
    Widget child = Padding(
      padding: const .only(left: 20, top: 6, right: 20),
      child: Row(
        mainAxisSize: .min,
        children: [
          avatars(
            gap: 10,
            colorScheme: colorScheme,
            users: list,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              list.map((e) => e.name).join('、'),
              maxLines: 1,
              overflow: .ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            '${flag ? '等${item.items!.length}人' : ''}也关注了TA',
            style: TextStyle(fontSize: 13, color: colorScheme.outline),
          ),
          Icon(
            Icons.keyboard_arrow_right,
            size: 20,
            color: colorScheme.outline,
          ),
        ],
      ),
    );
    return GestureDetector(
      onTap: () => FollowedPage.toFollowedPage(mid: card.mid, name: card.name),
      child: child,
    );
  }
}

class HeaderIndicator extends StatefulWidget {
  const HeaderIndicator({
    super.key,
    required this.length,
    required this.pageController,
  });

  final int length;
  final PageController pageController;

  @override
  State<HeaderIndicator> createState() => _HeaderIndicatorState();
}

class _HeaderIndicatorState extends State<HeaderIndicator> {
  late double _progress;

  @override
  void initState() {
    super.initState();
    _updateProgress();
    widget.pageController.addListener(_listener);
  }

  void _listener() {
    _updateProgress();
    setState(() {});
  }

  void _updateProgress() {
    _progress = ((widget.pageController.page ?? 0) + 1) / widget.length;
  }

  @override
  void dispose() {
    widget.pageController.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LinearProgressIndicator(
      // ignore: deprecated_member_use
      year2023: true,
      minHeight: 3.5,
      backgroundColor: const Color(0xA09E9E9E),
      value: _progress,
    );
  }
}

class HeaderTitle extends StatefulWidget {
  const HeaderTitle({
    super.key,
    required this.images,
    required this.pageController,
  });

  final List<TopImage> images;
  final PageController pageController;

  @override
  State<HeaderTitle> createState() => _HeaderTitleState();
}

class _HeaderTitleState extends State<HeaderTitle> {
  late int _index;

  @override
  void initState() {
    super.initState();
    _updateIndex();
    widget.pageController.addListener(_listener);
  }

  void _listener() {
    _updateIndex();
    setState(() {});
  }

  void _updateIndex() {
    _index = widget.pageController.page?.round() ?? 0;
  }

  @override
  void dispose() {
    widget.pageController.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.images[_index].title;
    if (title == null) return const SizedBox.shrink();
    return _headerTitle(title);
  }
}

Widget _headerTitle(TopTitle title) {
  try {
    return Column(
      crossAxisAlignment: .end,
      children: [
        Text(
          title.title!,
          maxLines: 1,
          overflow: .ellipsis,
          style: const TextStyle(fontSize: 12, color: Colors.white),
        ),
        if (title.subTitle?.isNotEmpty ?? false)
          Text(
            title.subTitle!,
            style: TextStyle(
              fontSize: 12,
              fontFamily: Assets.digitalNum,
              color: title.subTitleColorFormat?.colors?.isNotEmpty == true
                  ? ColourUtils.parseMedalColor(
                      title.subTitleColorFormat!.colors!.last,
                    )
                  : Colors.white,
            ),
          ),
      ],
    );
  } catch (e, s) {
    if (kDebugMode) {
      Utils.reportError(e, s);
    }
    return const SizedBox.shrink();
  }
}

Widget _headerWrapper(Widget child) {
  return IgnorePointer(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 125),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: .centerLeft,
            end: .centerRight,
            colors: [
              Colors.transparent,
              Colors.black12,
              Colors.black38,
              Colors.black45,
            ],
          ),
        ),
        child: Padding(
          padding: const .only(left: 15, right: 5, bottom: 2),
          child: child,
        ),
      ),
    ),
  );
}
