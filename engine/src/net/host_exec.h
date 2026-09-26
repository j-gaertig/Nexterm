#ifndef NEXTERM_HOST_EXEC_H
#define NEXTERM_HOST_EXEC_H

#include <stdint.h>

struct nexterm_control_plane;

int nexterm_host_exec(struct nexterm_control_plane* cp,
                      const char* request_id,
                      const char* command,
                      uint32_t timeout_ms);

void nexterm_host_exec_wait_idle(void);

#endif
