/*
 * r1tone: play a sine on card 0, device 0, to test audio on the mainline
 * kernel.
 *
 *   r1tone [freq_hz [level_dbfs [seconds [rate]]]]   default 440 -30 3 44100
 *
 * Stereo S16_LE, both channels the same.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tinyalsa/pcm.h>

#define PERIOD_FRAMES 1024

int main(int argc, char **argv)
{
	double freq = argc > 1 ? atof(argv[1]) : 440;
	double level = argc > 2 ? atof(argv[2]) : -30;
	double seconds = argc > 3 ? atof(argv[3]) : 3;
	unsigned int rate = argc > 4 ? atoi(argv[4]) : 44100;
	struct pcm_config config = {
		.channels = 2,
		.rate = rate,
		.period_size = PERIOD_FRAMES,
		.period_count = 4,
		.format = PCM_FORMAT_S16_LE,
	};
	double amp = 32767 * pow(10, level / 20), phase = 0;
	long frames = seconds * rate;
	short buf[PERIOD_FRAMES * 2];
	struct pcm *pcm;

	if (level > 0) {
		fprintf(stderr, "r1tone: level must be at most 0 dBFS\n");
		return 1;
	}
	pcm = pcm_open(0, 0, PCM_OUT, &config);
	if (!pcm || !pcm_is_ready(pcm)) {
		fprintf(stderr, "r1tone: %s\n", pcm ? pcm_get_error(pcm) : "pcm_open failed");
		return 1;
	}
	printf("r1tone: %.0f Hz at %.0f dBFS for %.1f s, %u Hz\n", freq, level, seconds, rate);
	while (frames > 0) {
		int n = frames < PERIOD_FRAMES ? frames : PERIOD_FRAMES, i;

		for (i = 0; i < n; i++) {
			short v = amp * sin(phase);

			buf[2 * i] = buf[2 * i + 1] = v;
			phase += 2 * M_PI * freq / rate;
			if (phase > 2 * M_PI)
				phase -= 2 * M_PI;
		}
		if (pcm_writei(pcm, buf, n) < 0) {
			fprintf(stderr, "r1tone: %s\n", pcm_get_error(pcm));
			pcm_close(pcm);
			return 1;
		}
		frames -= n;
	}
	pcm_close(pcm);
	return 0;
}
