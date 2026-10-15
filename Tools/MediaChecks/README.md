# Spotify konum doğrulama araçları (salt okuma)

Spotify'a hiçbir komut göndermezler; yalnızca `player state`, `player position`, `duration`, `id` okurlar.
Kişisel medya verisi (başlık/sanatçı) yazmazlar; parça kimliği kısa özetle tutulur. Çıktılar özel kanıt alanında kalmalıdır.

- `SpotifySourceProbe.swift`: uygulamanın gerçek `ScriptedPlayerSource`, `NowPlaying`, `ScriptRunner`, `BackendHealth`
  kaynaklarıyla derlenir (`import IslandCore` satırı çıkarılmış kopyalar). Ham dağıtık bildirim alanlarını, kaynağın yayınladığı
  modeli ve Spotify'ın gerçek konumunu yan yana yazar. `usage: probe [saniye] [aralık]`
- `MediaPanelAXProbe.swift`: çalışan bir TEST örneğinde (ayrı defaults/support ile başlatılmış) adayı genişletir, Medya sekmesini
  açık tutar ve panelin gösterdiği "geçen / toplam" erişilebilirlik değerini + Spotify gerçeğini kaydeder. Erişilebilirlik izni gerekir.
