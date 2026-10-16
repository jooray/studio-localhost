import 'dart:math';

final _rng = Random();
int randomSeed() => _rng.nextInt(1 << 31);
