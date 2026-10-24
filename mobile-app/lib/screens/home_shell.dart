// Bottom navigation with four tabs, labels always visible.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/theme.dart';

import 'alert_widgets.dart';
import 'aware_screen.dart';
import 'eyes_screen.dart';
import 'link_widgets.dart';
import 'today_screen.dart';
import 'together_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  static const _tabs = [TodayScreen(), AwareScreen(), EyesScreen(), TogetherScreen()];

  @override
  Widget build(BuildContext context) {
    return LinkAnnouncer(
      child: AlertAnnouncer(
        child: Scaffold(
          body: IndexedStack(index: _tab, children: _tabs),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(icon: Icon(Symbols.today_rounded), label: 'Today'),
              NavigationDestination(icon: Icon(Symbols.radar_rounded), label: 'Aware'),
              NavigationDestination(icon: Icon(Symbols.visibility_rounded), label: 'Eyes'),
              NavigationDestination(icon: Icon(Symbols.groups_rounded), label: 'Together'),
            ],
          ),
        ),
      ),
    );
  }
}

/// Common layout for a tab: app bar + scrolling list with page margins.
/// The current alert is pinned under the app bar on every tab, so it never
/// scrolls away. Tabs other than Today show the link-lost banner at the top
/// when the glasses aren't watching (Today shows the full StatusStrip
/// instead).
class TabPage extends StatelessWidget {
  const TabPage({super.key, required this.title, required this.children, this.actions, this.linkBanner = true});

  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  final bool linkBanner;

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    return Scaffold(
      appBar: AppBar(
        title: Semantics(header: true, child: Text(title)),
        actions: actions,
      ),
      body: Column(
        children: [
          LiveAlertBanner(padding: EdgeInsets.fromLTRB(space.page, space.s, space.page, 0)),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(space.page, space.s, space.page, space.xl),
              children: [
                if (linkBanner) const LiveStatusStrip(bannerOnly: true),
                for (final child in children)
                  Padding(
                    padding: EdgeInsets.only(top: space.cardGap),
                    child: child,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
