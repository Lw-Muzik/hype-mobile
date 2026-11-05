import 'package:flutter/material.dart';

class OnboardingPage {
  final String title;
  final String subtitle;
  final IconData icon;
  final List<String> features;
  final Color accentColor;

  const OnboardingPage({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.features,
    this.accentColor = const Color(0xFFD4A825),
  });
}

const List<OnboardingPage> onboardingPages = [
  OnboardingPage(
    title: 'Welcome to\nHype Muzik',
    subtitle: 'Your ultimate music experience',
    icon: Icons.headphones_rounded,
    features: [
      'Play local, cloud & streaming music',
      'Professional C++ audio engine',
      'Beautiful visualizations & lyrics',
    ],
  ),
  OnboardingPage(
    title: 'Discover\nNew Music',
    subtitle: 'Explore trending Ugandan hits',
    icon: Icons.explore_rounded,
    features: [
      'Hot 100 chart & popular songs',
      'Browse artists & stream instantly',
      'Search & play from the cloud',
    ],
    accentColor: Color(0xFFFF6B35),
  ),
  OnboardingPage(
    title: 'Studio-Grade\nEqualizer',
    subtitle: 'Shape your sound',
    icon: Icons.equalizer_rounded,
    features: [
      '32-band graphic EQ with presets',
      'Parametric EQ & tone controls',
      '10-band multiband compressor',
    ],
    accentColor: Color(0xFF5EC4D4),
  ),
  OnboardingPage(
    title: 'Room Effects\n& Spatial Audio',
    subtitle: 'Transform your listening space',
    icon: Icons.spatial_audio_rounded,
    features: [
      'Reverb with 11 room presets',
      'Stereo expander & crossfeed',
      'Output limiter for clean sound',
    ],
    accentColor: Color(0xFF9C6ADE),
  ),
  OnboardingPage(
    title: 'Cloud &\nStreaming',
    subtitle: 'Your music, everywhere',
    icon: Icons.cloud_rounded,
    features: [
      'Google Drive & Dropbox integration',
      'Smart caching & data saver mode',
      'Gapless playback & crossfade',
    ],
    accentColor: Color(0xFF4CAF50),
  ),
  OnboardingPage(
    title: 'Visualizers\n& Lyrics',
    subtitle: 'See your music come alive',
    icon: Icons.auto_awesome_rounded,
    features: [
      'Spectrum, radial & waveform visualizers',
      'Synchronized lyrics display',
      'Track fingerprinting with one tap',
    ],
    accentColor: Color(0xFFE91E63),
  ),
];
