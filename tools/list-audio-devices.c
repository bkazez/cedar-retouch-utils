/* list-audio-devices: List PortAudio output devices with indices.
 * Build: cc -o list-audio-devices list-audio-devices.c -lportaudio
 */

#include <stdio.h>
#include <portaudio.h>

int main(void)
{
    PaError err = Pa_Initialize();
    if (err != paNoError) {
        fprintf(stderr, "PortAudio init failed: %s\n", Pa_GetErrorText(err));
        return 1;
    }

    int count = Pa_GetDeviceCount();
    if (count < 0) {
        fprintf(stderr, "PortAudio error: %s\n", Pa_GetErrorText(count));
        Pa_Terminate();
        return 1;
    }

    PaDeviceIndex default_out = Pa_GetDefaultOutputDevice();

    for (int i = 0; i < count; i++) {
        const PaDeviceInfo *info = Pa_GetDeviceInfo(i);
        if (info == NULL || info->maxOutputChannels < 1)
            continue;
        const PaHostApiInfo *api = Pa_GetHostApiInfo(info->hostApi);
        const char *api_name = api ? api->name : "?";
        const char *marker = (i == default_out) ? " *" : "";
        printf("%3d  %-40s  [%s]%s\n", i, info->name, api_name, marker);
    }

    Pa_Terminate();
    return 0;
}
