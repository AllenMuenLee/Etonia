/// The touches the page's canvases have taken for themselves, such as a
/// finger moving the ruler. The scrolling view above
/// them skips a claimed touch, so it does not also pan the page.
///
/// Pointer events reach the canvas, deeper in the tree, before they reach
/// the view, so a claim is always made in time.
class PointerClaims {
  final Set<int> _pointers = <int>{};

  bool contains(int pointer) => _pointers.contains(pointer);

  void claim(int pointer) => _pointers.add(pointer);

  void release(int pointer) => _pointers.remove(pointer);

  bool get isEmpty => _pointers.isEmpty;
}
