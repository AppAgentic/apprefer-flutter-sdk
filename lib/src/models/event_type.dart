enum EventType {
  install('INSTALL'),
  login('LOGIN'),
  signUp('SIGN_UP'),
  register('REGISTER'),
  purchase('PURCHASE'),
  addToCart('ADD_TO_CART'),
  addToWishlist('ADD_TO_WISHLIST'),
  initiateCheckout('INITIATE_CHECKOUT'),
  startTrial('START_TRIAL'),
  subscribe('SUBSCRIBE'),
  levelStart('LEVEL_START'),
  levelComplete('LEVEL_COMPLETE'),
  tutorialComplete('TUTORIAL_COMPLETE'),
  search('SEARCH'),
  viewItem('VIEW_ITEM'),
  viewContent('VIEW_CONTENT'),
  share('SHARE'),
  custom('CUSTOM');

  final String value;

  const EventType(this.value);

  static EventType fromString(String value) {
    return EventType.values.firstWhere(
      (e) => e.value == value,
      orElse: () => EventType.custom,
    );
  }
}
