cmake_minimum_required(VERSION 3.5.0)
project(h264enc)

add_library(h264enc SHARED h264enc.c)

target_link_libraries(h264enc PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_media_codecbase.so
    libnative_media_core.so
    libnative_media_venc.so
    libnative_window.so
)
target_link_libraries(h264enc PUBLIC
    libnative_image.so
    libnative_buffer.so
)
