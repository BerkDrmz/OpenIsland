# Canlı erişilebilirlik denetimleri (yalnızca TEST örneğinde)

- `AXTabsKeys.swift`: test örneğini AX ile genişletir, altı sekmeye geçip oturmuş ekran görüntüleri alır (Kontrastı Artır karşılaştırması).
- `AXKeyboardFocus.swift`: Ctrl-Option-Cmd-I ile adayı açar (kurulu uygulama kısayolu tuttuğu için o sırada kapalı olmalı),
  Tab / Shift-Tab'ı yalnızca test sürecine gönderir ve odaktaki öğeyi yazar. Tam Klavye Erişimi açık olmalıdır.
Sistem ayarları bu araçlarca değiştirilmez; kullanıcı açar/kapatır.
