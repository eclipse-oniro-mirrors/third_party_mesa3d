# Copyright © 2017-2019 Intel Corporation
# SPDX-License-Identifier: MIT

inc_egl = include_directories('.', 'main')

c_args_for_egl = [asan_c_args]
cpp_args_for_egl = []
link_args_for_egl = []
link_deps_for_egl = []
link_for_egl = [libpipe_loader_dynamic]
if with_dri
  link_for_egl += libgallium_dri
endif
if with_platform_windows
  link_for_egl += libgallium_wgl
endif
deps_for_egl = []
incs_for_egl = [inc_include, inc_src, inc_egl]

files_egl = files(
  'main/eglapi.c',
  'main/eglarray.c',
  'main/eglarray.h',
  'main/eglconfigdebug.c',
  'main/eglconfigdebug.h',
  'main/eglconfig.c',
  'main/eglconfig.h',
  'main/eglcontext.c',
  'main/eglcontext.h',
  'main/eglcurrent.c',
  'main/eglcurrent.h',
  'main/egldefines.h',
  'main/egldevice.c',
  'main/egldevice.h',
  'main/egldisplay.c',
  'main/egldisplay.h',
  'main/egldriver.h',
  'main/eglglobals.c',
  'main/eglglobals.h',
  'main/eglimage.c',
  'main/eglimage.h',
  'main/egllog.c',
  'main/egllog.h',
  'main/eglsurface.c',
  'main/eglsurface.h',
  'main/eglsync.c',
  'main/eglsync.h',
  'main/eglentrypoint.h',
  'main/egltypedefs.h',
)

g_egldispatchstubs_c = custom_target(
  'g_egldispatchstubs.c',
  input : [
    'generate/gen_egl_dispatch.py',
    'generate/egl.xml', 'generate/egl_other.xml'
  ],
  output : 'g_egldispatchstubs.c',
  command : [
    prog_python, '@INPUT0@', 'source', '@INPUT1@', '@INPUT2@',
  ],
  depend_files : [ files('generate/eglFunctionList.py'), genCommon_py, ],
  capture : true,
)

g_egldispatchstubs_h = custom_target(
  'g_egldispatchstubs.h',
  input : [
    'generate/gen_egl_dispatch.py',
    'generate/egl.xml', 'generate/egl_other.xml'
  ],
  output : 'g_egldispatchstubs.h',
  command : [
    prog_python, '@INPUT0@', 'header', '@INPUT1@', '@INPUT2@',
  ],
  depend_files : [ files('generate/eglFunctionList.py'), genCommon_py, ],
  capture : true,
)

if with_dri
  files_egl += files(
    'drivers/dri2/egl_dri2.c',
    'drivers/dri2/egl_dri2.h',
  )
  files_egl += sha1_h
  deps_for_egl += idep_xmlconfig
  link_for_egl += libloader
  incs_for_egl += inc_loader
  incs_for_egl += inc_loader_x11
  incs_for_egl += inc_gallium
  incs_for_egl += inc_gallium_aux
  incs_for_egl += inc_mesa
  incs_for_egl += inc_st_dri

  files_egl += files(
    'drivers/dri2/platform_device.c',
    'drivers/dri2/platform_surfaceless.c',
  )

  if with_platform_x11
    files_egl += files('drivers/dri2/platform_x11.c')
    if with_dri_platform == 'drm'
      files_egl += files('drivers/dri2/platform_x11_dri3.c')
      link_for_egl += [libloader_x11]
    endif
    deps_for_egl += [dep_x11_xcb, dep_xcb_dri2, dep_xcb_xrandr, dep_xcb_xfixes, dep_xcb_shm]
  endif
  if with_gbm and not with_platform_android and not with_platform_ohos
    files_egl += files('drivers/dri2/platform_drm.c')
    link_for_egl += libgbm
    incs_for_egl += [inc_gbm, include_directories('../gbm/main')]
    deps_for_egl += dep_libdrm
  endif
  if with_platform_wayland
    deps_for_egl += [dep_wayland_client, dep_wayland_server, dep_wayland_egl_headers]
    link_for_egl += [libwayland_drm, libloader_wayland_helper]
    files_egl += files('drivers/dri2/platform_wayland.c')
    files_egl += wp_files['linux-dmabuf-unstable-v1']
    files_egl += [wayland_drm_client_protocol_h]
    incs_for_egl += include_directories('wayland/wayland-drm')
  endif
  if with_platform_android
    deps_for_egl += [dep_android, idep_u_gralloc]
    files_egl += files('drivers/dri2/platform_android.c')
  endif
  if with_platform_ohos
    deps_for_egl += [dependency('libsurface')]
    files_egl += files('drivers/dri2/platform_ohos.c')
  endif
elif with_platform_haiku
  c_args_for_egl += [
    '-D_EGL_BUILT_IN_DRIVER_HAIKU',
  ]
  files_egl += files('drivers/haiku/egl_haiku.cpp')

  incs_for_egl += [inc_gallium, inc_gallium_aux, inc_gallium_drivers, inc_gallium_winsys, inc_gallium_winsys_sw]
  incs_for_egl += [inc_mesa, inc_mapi]
  incs_for_egl += [include_directories('../gallium/frontends/hgl')]

  link_for_egl += [libmesa, libgallium, libswhgl, libsthgl]
  deps_for_egl += [cpp.find_library('be'), driver_swrast]
elif with_platform_windows
  c_args_for_egl += [
    '-DEGLAPI=', '-DPUBLIC='
  ]
  files_egl += files('drivers/wgl/egl_wgl.c')
  incs_for_egl += [inc_wgl, inc_gallium, inc_gallium_aux, inc_mesa, inc_mapi]
  link_for_egl += libgallium_wgl

else
  error('No EGL driver available.')
endif

if cc.has_function('mincore')
  c_args_for_egl += '-DHAVE_MINCORE'
endif

if not with_glvnd
  egl_lib_name = 'EGL' + get_option('egl-lib-suffix')
  egl_lib_version = '1.0.0'
  egl_lib_soversion = host_machine.system() == 'windows' ? '' : '1'
else
  egl_lib_name = 'EGL_@0@'.format(glvnd_vendor_name)
  egl_lib_version = '0.0.0'
  egl_lib_soversion = '0'
  deps_for_egl += dep_glvnd
  files_egl += [g_egldispatchstubs_h, g_egldispatchstubs_c]
  files_egl += files('main/eglglvnd.c', 'main/egldispatchstubs.c')
  glvnd_config = configuration_data()
  glvnd_config.set('glvnd_vendor_name', get_option('glvnd-vendor-name'))
  configure_file(
    configuration: glvnd_config,
    input : 'main/50_mesa.json',
    output: '50_@0@.json'.format(glvnd_vendor_name),
    install : true,
    install_tag : 'runtime',
    install_dir : join_paths(get_option('datadir'), 'glvnd', 'egl_vendor.d')
  )
endif

if with_ld_version_script
  if with_glvnd
    link_args_for_egl += [
      '-Wl,--version-script', join_paths(meson.current_source_dir(), 'egl-glvnd.sym')
    ]
    link_deps_for_egl += files('egl-glvnd.sym')
  else
    link_args_for_egl += [
      '-Wl,--version-script', join_paths(meson.current_source_dir(), 'egl.sym')
    ]
    link_deps_for_egl += files('egl.sym')
  endif
endif

egl_def = custom_target(
  'egl.def',
  input: 'main/egl.def.in',
  output : 'egl.def',
  command : gen_vs_module_defs_normal_command,
)

libegl = shared_library(
  egl_lib_name,
  files_egl,
  c_args : [
    c_args_for_egl,
    '-D_EGL_NATIVE_PLATFORM=_EGL_PLATFORM_@0@'.format(egl_native_platform.to_upper()),
  ],
  cpp_args : [cpp_args_for_egl],
  gnu_symbol_visibility : 'hidden',
  include_directories : incs_for_egl,
  link_with : [link_for_egl],
  link_args : [ld_args_bsymbolic, ld_args_gc_sections, link_args_for_egl],
  link_depends : [link_deps_for_egl],
  dependencies : [deps_for_egl, dep_dl, dep_libdrm, dep_clock, dep_thread, idep_mesautil],
  install : true,
  name_prefix : host_machine.system() == 'windows' ? 'lib' : [],  # always use lib, but avoid warnings on !windows
  vs_module_defs : egl_def
)

if not with_glvnd
  pkg.generate(
    name : 'egl',
    description : 'Mesa EGL Library',
    version : meson.project_version(),
    libraries : libegl,
    libraries_private: gl_priv_libs,
    requires_private : gl_priv_reqs,
    extra_cflags : gl_pkgconfig_c_flags,
  )
endif

if with_symbols_check
  if with_glvnd
    egl_symbols = files('egl-glvnd-symbols.txt')
  else
    egl_symbols = files('egl-symbols.txt')
  endif
  test('egl-symbols-check',
    symbols_check,
    args : [
      '--lib', libegl,
      '--symbols-file', egl_symbols,
      symbols_check_args,
    ],
    suite : ['egl'],
  )
  test('egl-entrypoint-check',
    prog_python,
    args : files('egl-entrypoint-check.py', 'main/eglentrypoint.h'),
    suite : ['egl'],
  )
endif
