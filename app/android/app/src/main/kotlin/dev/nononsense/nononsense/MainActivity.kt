package dev.nononsense.nononsense

import com.ryanheise.audioservice.AudioServiceActivity

// audio_service's activity: it shares one Flutter engine with the playback service (lib/core/media_controls.dart)
class MainActivity : AudioServiceActivity()
