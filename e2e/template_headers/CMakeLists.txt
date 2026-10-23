cmake_minimum_required(VERSION 3.20)
project(template_headers LANGUAGES CXX)
find_path(BOOST_INCLUDE_DIR boost/version.hpp
    PATHS "${DECLARED_BOOST_ROOT}/include" NO_DEFAULT_PATH REQUIRED)
message(STATUS "Declared Boost headers: ${BOOST_INCLUDE_DIR}")
add_library(template_headers STATIC probe.cc)
target_compile_features(template_headers PRIVATE cxx_std_11)
target_include_directories(template_headers SYSTEM PRIVATE "${BOOST_INCLUDE_DIR}")
install(TARGETS template_headers ARCHIVE DESTINATION lib)
