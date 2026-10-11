import 'package:flutter/widgets.dart';

/// Phone windows use bottom navigation rather than the desktop sidebar. This threshold leaves
/// enough room for a readable search field and song rows on compact Android devices.
const phoneWidth = 700.0;

bool isPhone(BuildContext context) =>
    MediaQuery.sizeOf(context).width < phoneWidth;
