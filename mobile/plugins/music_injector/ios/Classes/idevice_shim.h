#ifndef IDEVICE_SHIM_H
#define IDEVICE_SHIM_H

// Dichiarazioni minime delle funzioni idevice-ffi usate dal plugin.
// Le firme complete sono in idevice.h generato da cbindgen durante
// la build Rust (viene copiato in questa cartella dal podspec).

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct IdeviceFfiError IdeviceFfiError;
typedef struct IdeviceProviderHandle IdeviceProviderHandle;
typedef struct IdevicePairingFile IdevicePairingFile;
typedef struct AfcClientHandle AfcClientHandle;
typedef struct AfcFileHandle AfcFileHandle;
typedef struct AfcFileInfo AfcFileInfo;
typedef struct AfcDeviceInfo AfcDeviceInfo;
typedef struct LockdowndClientHandle LockdowndClientHandle;

typedef enum {
  AfcRdOnly = 0,
  AfcWrOnly = 1,
  AfcRdWr = 2,
  AfcWrAppend = 3,
} AfcFileMode;

// Errori
void idevice_error_free(IdeviceFfiError *err);
const char *idevice_error_message(IdeviceFfiError *err);
int32_t idevice_error_code(IdeviceFfiError *err);

// Pairing file
IdeviceFfiError *idevice_pairing_file_read(const char *path, IdevicePairingFile **out);
void idevice_pairing_file_free(IdevicePairingFile *pf);

// Provider TCP (ci colleghiamo a 127.0.0.1:27015, usbmuxd locale iOS)
IdeviceFfiError *idevice_tcp_provider_new(const void *sockaddr, size_t socklen,
                                           const char *label,
                                           IdeviceProviderHandle **out);
void idevice_provider_free(IdeviceProviderHandle *provider);

// Lockdown
IdeviceFfiError *lockdownd_connect(IdeviceProviderHandle *provider,
                                   LockdowndClientHandle **out);
IdeviceFfiError *lockdownd_start_session(LockdowndClientHandle *client,
                                         IdevicePairingFile *pairing_file);
IdeviceFfiError *lockdownd_pair(LockdowndClientHandle *client,
                                IdevicePairingFile *pairing_file);
IdeviceFfiError *lockdownd_start_service(LockdowndClientHandle *client,
                                         const char *service_name,
                                         uint16_t *port, int *ssl,
                                         const char *label);
void lockdownd_client_free(LockdowndClientHandle *client);

// AFC
IdeviceFfiError *afc_client_connect(IdeviceProviderHandle *provider,
                                    AfcClientHandle **out);
void afc_client_free(AfcClientHandle *client);
IdeviceFfiError *afc_list_directory(AfcClientHandle *client, const char *path,
                                    char ***entries, size_t *count);
void afc_free_directory_listing(char **entries, size_t count);
IdeviceFfiError *afc_make_directory(AfcClientHandle *client, const char *path);
IdeviceFfiError *afc_remove_path(AfcClientHandle *client, const char *path);
IdeviceFfiError *afc_get_file_info(AfcClientHandle *client, const char *path,
                                   AfcFileInfo **out);
void afc_file_info_free(AfcFileInfo *info);
IdeviceFfiError *afc_get_device_info(AfcClientHandle *client,
                                     AfcDeviceInfo **out);
void afc_device_info_free(AfcDeviceInfo *info);

IdeviceFfiError *afc_file_open(AfcClientHandle *client, const char *path,
                               AfcFileMode mode, AfcFileHandle **out);
IdeviceFfiError *afc_file_close(AfcFileHandle *file);
IdeviceFfiError *afc_file_write(AfcFileHandle *file, const uint8_t *data,
                                size_t length);
IdeviceFfiError *afc_file_read_entire(AfcFileHandle *file, uint8_t **data,
                                      size_t *length);
IdeviceFfiError *afc_file_read(AfcFileHandle *file, uint8_t *data,
                               size_t length, size_t *bytes_read);
IdeviceFfiError *afc_file_read_data_free(uint8_t *data, size_t length);

#ifdef __cplusplus
}
#endif

#endif
