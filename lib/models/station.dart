/// A radio station: a display name, an Icecast/Shoutcast stream URL, and an
/// optional user-chosen colour (ARGB int) for its list entry — null ⇒ the
/// default theme colour. Lets the user tag stations by genre / favourite.
class Station {
  const Station(this.name, this.url, {this.color});
  final String name;
  final String url;
  final int? color;

  Map<String, dynamic> toJson() =>
      {'name': name, 'url': url, if (color != null) 'color': color};
  factory Station.fromJson(Map<String, dynamic> j) => Station(
        j['name'] as String,
        j['url'] as String,
        color: (j['color'] as num?)?.toInt(),
      );
}
