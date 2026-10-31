import 'package:flutter/material.dart' as flutter_material;
import 'package:flutter/material.dart' hide Text;
import '../search/conversion.dart';
import '../settings/display_settings.dart';
import '../settings/display_settings_ui.dart';

String displayText(String text, [BuildContext? context]) {
  if (context != null) ScriptDisplayScope.dependOn(context);
  if (scriptureDisplaySettings.showOriginalText) return text;
  return scriptureDisplaySettings.showSimplifiedText
      ? SimplifiedTraditionalConverter.toSimplified(text)
      : SimplifiedTraditionalConverter.toTraditionalDisplay(text);
}

InlineSpan displayInlineSpan(InlineSpan span) {
  if (span is! flutter_material.TextSpan) return span;
  return flutter_material.TextSpan(
    text: span.text == null ? null : displayText(span.text!),
    children: span.children?.map(displayInlineSpan).toList(),
    style: span.style,
    recognizer: span.recognizer,
    mouseCursor: span.mouseCursor,
    onEnter: span.onEnter,
    onExit: span.onExit,
    semanticsLabel: span.semanticsLabel == null
        ? null
        : displayText(span.semanticsLabel!),
    semanticsIdentifier: span.semanticsIdentifier,
    locale: span.locale,
    spellOut: span.spellOut,
  );
}

class Text extends StatelessWidget {
  const Text(
    this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : textSpan = null;

  const Text.rich(
    this.textSpan, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : data = null;

  final String? data;
  final InlineSpan? textSpan;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final String? semanticsIdentifier;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;

  @override
  Widget build(BuildContext context) {
    ScriptDisplayScope.dependOn(context);
    final displayedSpan = textSpan;
    final semantics = semanticsLabel == null
        ? null
        : displayText(semanticsLabel!);
    if (displayedSpan != null) {
      return flutter_material.Text.rich(
        displayInlineSpan(displayedSpan),
        style: style,
        strutStyle: strutStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        locale: locale,
        softWrap: softWrap,
        overflow: overflow,
        textScaler: textScaler,
        maxLines: maxLines,
        semanticsLabel: semantics,
        semanticsIdentifier: semanticsIdentifier,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        selectionColor: selectionColor,
      );
    }
    return flutter_material.Text(
      displayText(data!),
      style: style,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      locale: locale,
      softWrap: softWrap,
      overflow: overflow,
      textScaler: textScaler,
      maxLines: maxLines,
      semanticsLabel: semantics,
      semanticsIdentifier: semanticsIdentifier,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor,
    );
  }
}

class DisplaySelectableText extends StatelessWidget {
  const DisplaySelectableText(this.data, {super.key, this.style});

  final String data;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    ScriptDisplayScope.dependOn(context);
    return flutter_material.SelectableText(displayText(data), style: style);
  }
}
