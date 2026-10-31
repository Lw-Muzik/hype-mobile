// import 'package:flutter/material.dart';

// import '../pages/loader.dart';

// class RipplePainter extends CustomPainter {
//   final List<Ripple> ripples;

//   RipplePainter(this.ripples);

//   @override
//   void paint(Canvas canvas, Size size) {
//     final paint = Paint()
//       ..color = Colors.white
//           .withValues(alpha: 0.07124) // Adjust the ripple color and opacity.
//       ..style = PaintingStyle.fill;
//     // ..fillWidth = 2.0;

//     for (var ripple in ripples) {
//       final radius =
//           ripple.controller.value * 50.0 * 6; // Adjust the ripple size.
//       canvas.drawCircle(
//         Offset(size.width / 2, size.height / 2),
//         radius,
//         paint,
//       );
//     }
//   }

//   @override
//   bool shouldRepaint(covariant CustomPainter oldDelegate) {
//     return true;
//   }
// }
