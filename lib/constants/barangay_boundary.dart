import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Barangay boundary polygon, split out of TanodLocationScreen so that
/// screen doesn't get crowded with a giant hardcoded coordinate list.
///
/// Source: exported GeoJSON polygon (single outer ring, no holes).
/// Coordinates below are already converted from GeoJSON's [lng, lat]
/// order to flutter_map's LatLng(lat, lng) order.
class BarangayBoundary {
  BarangayBoundary._();

  /// The boundary ring, in order, first point repeated as the last point
  /// (as GeoJSON polygons do) so it closes visually without extra logic.
  static const List<LatLng> points = [
    LatLng(14.6863863, 121.0695263),
    LatLng(14.6863799, 121.0698125),
    LatLng(14.6861434, 121.069793),
    LatLng(14.6859346, 121.0697833),
    LatLng(14.6857416, 121.0697998),
    LatLng(14.6854579, 121.0698677),
    LatLng(14.6852579, 121.0699112),
    LatLng(14.6850959, 121.0699177),
    LatLng(14.6849191, 121.0698873),
    LatLng(14.6844235, 121.0698191),
    LatLng(14.6841326, 121.0697664),
    LatLng(14.6838995, 121.0697339),
    LatLng(14.6836676, 121.0696963),
    LatLng(14.6834494, 121.0696377),
    LatLng(14.6831521, 121.0695691),
    LatLng(14.6828863, 121.0695502),
    LatLng(14.6825347, 121.0696044),
    LatLng(14.6823091, 121.0696288),
    LatLng(14.6821715, 121.069621),
    LatLng(14.6820433, 121.0695987),
    LatLng(14.6817235, 121.0695455),
    LatLng(14.6811863, 121.0695224),
    LatLng(14.6810446, 121.0695134),
    LatLng(14.6809156, 121.0694893),
    LatLng(14.6806752, 121.0694122),
    LatLng(14.680202, 121.0692498),
    LatLng(14.6799968, 121.0691926),
    LatLng(14.6799197, 121.0691731),
    LatLng(14.6798347, 121.0691666),
    LatLng(14.679692, 121.0691764),
    LatLng(14.6792075, 121.0692687),
    LatLng(14.6789382, 121.0692878),
    LatLng(14.6786336, 121.0692915),
    LatLng(14.6783789, 121.0692907),
    LatLng(14.6781356, 121.0692717),
    LatLng(14.6781287, 121.0742663),
    LatLng(14.6778617, 121.0745571),
    LatLng(14.6776105, 121.0748663),
    LatLng(14.6774287, 121.0748028),
    LatLng(14.6769876, 121.0746726),
    LatLng(14.6756947, 121.0746987),
    LatLng(14.6756807, 121.0781693),
    LatLng(14.6717708, 121.0781566),
    LatLng(14.6715792, 121.0783458),
    LatLng(14.6714227, 121.0785071),
    LatLng(14.6723987, 121.0794399),
    LatLng(14.6734909, 121.080299),
    LatLng(14.6757406, 121.0819345),
    LatLng(14.6770063, 121.0826559),
    LatLng(14.6782838, 121.0833038),
    LatLng(14.6809645, 121.0844876),
    LatLng(14.6837742, 121.0857001),
    LatLng(14.686625, 121.0868518),
    LatLng(14.6872342, 121.0870454),
    LatLng(14.6881663, 121.0872054),
    LatLng(14.6889238, 121.0872504),
    LatLng(14.6897291, 121.0872696),
    LatLng(14.6928427, 121.0873282),
    LatLng(14.6930135, 121.0862149),
    LatLng(14.6930899, 121.0856578),
    LatLng(14.6931662, 121.0851047),
    LatLng(14.6932316, 121.0848259),
    LatLng(14.6933461, 121.0845674),
    LatLng(14.6934924, 121.0843234),
    LatLng(14.6936079, 121.0840611),
    LatLng(14.6936946, 121.0837841),
    LatLng(14.6937656, 121.0835064),
    LatLng(14.6938222, 121.0832195),
    LatLng(14.6938541, 121.0829161),
    LatLng(14.6938105, 121.0828295),
    LatLng(14.6937553, 121.0827538),
    LatLng(14.6936464, 121.0826325),
    LatLng(14.6933128, 121.0824643),
    LatLng(14.6929992, 121.0821411),
    LatLng(14.6921994, 121.0813099),
    LatLng(14.692522, 121.0809704),
    LatLng(14.6926998, 121.0808514),
    LatLng(14.6928777, 121.0808132),
    LatLng(14.6930141, 121.0807704),
    LatLng(14.6930526, 121.0806857),
    LatLng(14.6930556, 121.0805172),
    LatLng(14.6930647, 121.0800993),
    LatLng(14.6930692, 121.0797533),
    LatLng(14.6930871, 121.0795775),
    LatLng(14.6931322, 121.0794276),
    LatLng(14.6931686, 121.0793637),
    LatLng(14.6932591, 121.0793278),
    LatLng(14.6934688, 121.0793512),
    LatLng(14.6936446, 121.0793653),
    LatLng(14.6938121, 121.0793575),
    LatLng(14.6938923, 121.0792227),
    LatLng(14.6939546, 121.0790112),
    LatLng(14.6938317, 121.0789542),
    LatLng(14.6937174, 121.0788627),
    LatLng(14.6936123, 121.0787705),
    LatLng(14.6932861, 121.0785121),
    LatLng(14.6931668, 121.0784317),
    LatLng(14.6930617, 121.0784828),
    LatLng(14.6927883, 121.0783231),
    LatLng(14.6926531, 121.0782364),
    LatLng(14.692582, 121.0781907),
    LatLng(14.6925364, 121.0781469),
    LatLng(14.692622, 121.078066),
    LatLng(14.692675, 121.0779967),
    LatLng(14.6927802, 121.0777505),
    LatLng(14.6929033, 121.0774776),
    LatLng(14.6930492, 121.0772045),
    LatLng(14.6930618, 121.0761555),
    LatLng(14.69307, 121.0740848),
    LatLng(14.6930603, 121.0730552),
    LatLng(14.6930589, 121.0725472),
    LatLng(14.6930607, 121.0724144),
    LatLng(14.6931181, 121.0722852),
    LatLng(14.6931213, 121.0721682),
    LatLng(14.6931211, 121.0720351),
    LatLng(14.693125, 121.0719048),
    LatLng(14.693138, 121.0716396),
    LatLng(14.6931494, 121.0713727),
    LatLng(14.6931653, 121.0711035),
    LatLng(14.6932151, 121.0705508),
    LatLng(14.6932283, 121.0704136),
    LatLng(14.6932357, 121.0702715),
    LatLng(14.6932236, 121.0701255),
    LatLng(14.6931981, 121.069907),
    LatLng(14.6863863, 121.0695263),
  ];

  /// Ready-to-drop-in polygon layer: a light fill with a solid outline.
  /// Add this as one of the `children` of your FlutterMap, alongside your
  /// TileLayer / MarkerLayer.
  static PolygonLayer layer({
    Color fillColor = const Color(0x1A2196F3), // ~10% opacity blue
    Color borderColor = const Color(0xFF2196F3),
    double borderWidth = 2.5,
  }) {
    return PolygonLayer(
      polygons: [
        Polygon(
          points: points,
          color: fillColor,
          borderColor: borderColor,
          borderStrokeWidth: borderWidth,
        ),
      ],
    );
  }

  /// Bounding box of the boundary — handy if you want the map to fit the
  /// whole barangay on load via CameraFit.bounds(bounds: boundsOfBoundary).
  static LatLngBounds get bounds => LatLngBounds.fromPoints(points);
}