// nn::vi (display layer): on a real device, the vi service is used to open the display, create a layer and get the native window handle; the handle is passed to NVN's window builder.
// Host: returns host static objects; when hooking up Metal, the native window corresponds to the front end's CAMetalLayer (front_metal_layer()).
#include "../host/hle.h"

static struct { uint32_t magic; } g_display = {0x50534944}, g_layer = {0x5259414c};
static struct { uint32_t magic; void *layer; } g_native = {0x4e49574e, 0};

HLE_FORCE("_ZN2nn2vi10InitializeEv", "显示服务初始化；宿主无 vi 服务", void, h_vi_Init, void) {}
HLE_FORCE("_ZN2nn2vi18OpenDefaultDisplayEPPNS0_7DisplayE", "开默认显示；宿主给静态对象", Result, h_vi_OpenDisp, void **out) {
    *out = &g_display; return RES_OK;
}
HLE_FORCE("_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayE", "建图层；宿主给静态对象", Result, h_vi_CreateLayer, void **out, void *disp) {
    (void)disp; *out = &g_layer; return RES_OK;
}
HLE_FORCE("_ZN2nn2vi15GetNativeWindowEPPvPNS0_5LayerE", "原生窗口句柄，交给 NVN 窗口 builder；宿主给静态对象", Result, h_vi_GetNative, void **out, void *layer) {
    (void)layer; *out = &g_native; return RES_OK;
}
// Link's Awakening also crops its layer and tears the display down on exit; the SDK's versions dereference the vi service objects the host never made (SetLayerCrop: SIGSEGV at +0x64)
HLE_FORCE("_ZN2nn2vi12SetLayerCropEPNS0_5LayerEiiii", "图层裁切；宿主出图不裁", Result, h_vi_SetCrop, void *layer, int x, int y, int w, int h) {
    (void)layer; LOG("vi::SetLayerCrop %d,%d %dx%d（忽略）", x, y, w, h); return RES_OK;
}
// Super Mario Odyssey sets its layer's scaling mode; the SDK's version uses the vi service objects the host never made
HLE_FORCE("_ZN2nn2vi19SetLayerScalingModeEPNS0_5LayerENS0_11ScalingModeE", "图层缩放方式；宿主出图自己缩放", Result, h_vi_SetScaling, void *layer, int mode) {
    (void)layer; LOG("vi::SetLayerScalingMode %d（忽略）", mode); return RES_OK;
}
HLE_FORCE("_ZN2nn2vi12DestroyLayerEPNS0_5LayerE", "销毁图层；宿主静态对象", void, h_vi_DestroyLayer, void *layer) { (void)layer; }
HLE_FORCE("_ZN2nn2vi12CloseDisplayEPNS0_7DisplayE", "关显示；宿主静态对象", void, h_vi_CloseDisp, void *disp) { (void)disp; }
HLE_FORCE("_ZN2nn2vi8FinalizeEv", "显示服务收尾；宿主无 vi 服务", void, h_vi_Fini, void) {}
