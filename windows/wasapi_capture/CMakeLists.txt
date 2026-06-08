cmake_minimum_required(VERSION 3.14)
project(wasapi_capture LANGUAGES CXX)

add_executable(wasapi_capture main.cpp)

target_compile_features(wasapi_capture PRIVATE cxx_std_17)
target_compile_options(wasapi_capture PRIVATE /W3 /EHsc)

target_link_libraries(wasapi_capture PRIVATE ole32 winmm)
