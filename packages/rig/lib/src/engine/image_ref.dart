/// Split an image reference into the name and tag the pull endpoint wants.
///
/// The tricky part is that a registry host can carry a port, so the last
/// colon is not always a tag separator: in `localhost:5000/team/app` the
/// colon belongs to the host. A colon only introduces a tag when it comes
/// after the last slash.
({String name, String tag}) splitImageRef(String image) {
  final at = image.lastIndexOf('@');
  if (at > 0) {
    return (name: image.substring(0, at), tag: image.substring(at + 1));
  }

  final slash = image.lastIndexOf('/');
  final colon = image.lastIndexOf(':');
  if (colon > slash) {
    return (name: image.substring(0, colon), tag: image.substring(colon + 1));
  }
  return (name: image, tag: 'latest');
}
