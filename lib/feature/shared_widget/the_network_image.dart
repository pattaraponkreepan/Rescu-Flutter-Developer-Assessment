import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

/// Standard network image with a shimmer placeholder.
class TheNetworkImage extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;

  const TheNetworkImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: LayoutBuilder(
        builder: (context, constraints) => CachedNetworkImage(
          imageUrl: url,
          width: width,
          height: height,
          fit: fit,
          memCacheWidth: _decodeWidth(context, constraints),
          placeholder: (context, _) => Shimmer.fromColors(
            baseColor: Colors.grey.shade300,
            highlightColor: Colors.grey.shade100,
            child: Container(width: width, height: height, color: Colors.white),
          ),
          errorWidget: (context, _, __) => Container(
            width: width,
            height: height,
            color: Colors.grey.shade200,
            child: const Icon(Icons.image_not_supported_outlined),
          ),
        ),
      ),
    );
  }

  /// Width in physical pixels to decode the image at. The API serves
  /// 1600x1200 sources (~7.3 MB each once decoded) that are drawn at a
  /// fraction of that size; decoding at display size keeps the image cache and
  /// GPU textures proportional to what is on screen.
  ///
  /// Sized to the box's larger side so a landscape source still covers the
  /// box with BoxFit.cover. Returns null (full size) if the box is unbounded.
  int? _decodeWidth(BuildContext context, BoxConstraints constraints) {
    final w = min(width ?? double.infinity, constraints.maxWidth);
    final h = min(height ?? double.infinity, constraints.maxHeight);
    final side = max(w.isFinite ? w : 0.0, h.isFinite ? h : 0.0);
    if (side == 0) return null;
    return (side * MediaQuery.devicePixelRatioOf(context)).round();
  }
}
