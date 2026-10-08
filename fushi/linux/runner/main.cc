#include "external_open_handoff.h"
#include "my_application.h"

int main(int argc, char** argv) {
  // 数据迁移自动重启：先等旧实例让出单实例名，再注册（见该函数注释）。
  fushi_wait_for_previous_instance_exit(argc, argv, APPLICATION_ID, 10000);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
