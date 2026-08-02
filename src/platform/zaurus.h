#ifndef PLATFORM_ZAURUS_H
#define PLATFORM_ZAURUS_H

/*	Sharp Zaurus SL-C860 (piko ROM), 2026.
	No hardware joystick/analog stick -- the SL-C860 is a clamshell PDA
	with a physical QWERTY keyboard plus a handful of dedicated buttons
	(jog dial, F-keys) read through the same corgi matrix-keypad driver.
	Values below are standard Linux VT scancode translations of those
	keys' KEY_* codes -- the same mechanism every other SDL1/fbcon
	platform in this tree relies on, not device-specific magic.

	BUTTON            GMENU          SDL             NUMERIC
	-----------------------------------------------------------------------
	Jog dial / cursor UP/DOWN/       SDLK_UP/DOWN/   273/274/
	  keys             LEFT/RIGHT     LEFT/RIGHT      276/275
	"OK" (F11)         CONFIRM        SDLK_F11        292
	"Cancel" (F4)      CANCEL         SDLK_F4         285
	  (the SL-C860 keyboard has no physical Escape key at all -- this
	  mirrors the fix otQuake needed for the same reason, see its
	  src/vid_fb.c comment block)
	"Menu" (F12)       MENU           SDLK_F12        293
	Return/Enter       SETTINGS       SDLK_RETURN     13
	Left Shift         MODIFIER       SDLK_LSHIFT     304
	Tab / Backspace    SECTION_PREV/  SDLK_TAB /      9/8
	                     NEXT           BACKSPACE

	Power button, volume, and the Fn+3/Fn+4 brightness hotkeys are left
	unbound in assets/zaurus/input.conf pending verification on real
	hardware -- brightd (piko's own hotkey daemon) already owns backlight
	independently of this app, and the exact power-button keycode wasn't
	established during porting.

	assets/zaurus/input.conf has no comments in it -- confirmed on real
	hardware that InputManager::readConf() (src/inputmanager.cpp) has no
	'#'-skip at all, so every '#'-led line just logs as an "Unknown
	action" instead of being ignored. Every other platform's input.conf
	is comment-free for the same reason; put explanations here instead.
*/

class Zaurus : public Platform {
public:
	Zaurus(GMenu2X *gmenu2x) : Platform(gmenu2x) {
		WARNING("Zaurus");

		rtc = true;
		tvout = false;
		udc = false;
		ext_sd = true;
		hw_scaler = false;
		joystick = false;
		volume = false; // no confirmed ALSA mixer control path yet
		ipk = false;    // piko's opkg needs an explicit root/card dest per
		                // install (see rootfs/usr/sbin/pkgadd); GMenuNX's
		                // built-in generic IPK installer doesn't pass one
		opk = "zaurus";

		w = 640;
		h = 480;
		bpp = 16;

		struct fb_var_screeninfo vinfo;
		int fbdev = open("/dev/fb0", O_RDWR);
		if (fbdev >= 0) {
			if (ioctl(fbdev, FBIOGET_VSCREENINFO, &vinfo) >= 0) {
				w = vinfo.xres;
				h = vinfo.yres;
				bpp = vinfo.bits_per_pixel;
			}
			close(fbdev);
		}
	};

	int16_t getBattery(bool raw) {
		int val = -1;
		int ac_line = -1;

		if (FILE *f = fopen("/proc/apm", "r")) {
			char driver_ver[16] = {0}, apm_ver[16] = {0}, percent_str[8] = {0}, unit[8] = {0};
			unsigned int apm_flags, batt_status, batt_flags;
			int life;
			if (fscanf(f, "%15s %15s %x %x %x %x %7s %d %7s",
					driver_ver, apm_ver, &apm_flags, (unsigned int*)&ac_line,
					&batt_status, &batt_flags, percent_str, &life, unit) >= 7) {
				val = atoi(percent_str);
			}
			fclose(f);
		}

		if (raw) return val;
		if (ac_line == 1) return 6; // on AC power / charging
		if (val < 0) return 6; // unknown
		if (val > 90) return 5; // 100%
		if (val > 75) return 4; // 80%
		if (val > 55) return 3; // 55%
		if (val > 30) return 2; // 30%
		if (val > 15) return 1; // 15%
		return 0; // 0% :(
	}

	int16_t getBacklight() {
		int val = -1, max = -1;
		if (FILE *f = fopen("/sys/class/backlight/corgi_bl/brightness", "r")) {
			fscanf(f, "%i", &val);
			fclose(f);
		}
		if (FILE *f = fopen("/sys/class/backlight/corgi_bl/max_brightness", "r")) {
			fscanf(f, "%i", &max);
			fclose(f);
		}
		if (val < 0 || max <= 0) return -1;
		return val * 100 / max;
	}

	void setBacklight(int val) {
		int max = -1;
		if (FILE *f = fopen("/sys/class/backlight/corgi_bl/max_brightness", "r")) {
			fscanf(f, "%i", &max);
			fclose(f);
		}
		if (max <= 0) max = 47; // corgi_lcd's compiled-in default, see piko's rootfs/usr/sbin/bright

		int level = val * max / 100;
		if (level < 0) level = 0;
		if (level > max) level = max;

		if (FILE *f = fopen("/sys/class/backlight/corgi_bl/brightness", "a")) {
			fprintf(f, "%d", level);
			fclose(f);
		}
	}

	string hwPreLinkLaunch() {
		return "";
	}
};

#endif
