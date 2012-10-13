PROJECT(transformer)
cmake_minimum_required(VERSION 2.6)

SET (CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/.orogen/config")
INCLUDE(transformerBase)

install(FILES ${PROJECT_SOURCE_DIR}/rock/orogen_plugin.rb
        DESTINATION ${CMAKE_INSTALL_PREFIX}/share/orogen/plugins
        RENAME transformer_plugin.rb)

install(FILES ${PROJECT_SOURCE_DIR}/rock/roby_plugin.rb
        DESTINATION ${CMAKE_INSTALL_PREFIX}/share/orogen/plugins/roby
        RENAME transformer_plugin.rb)

list(APPEND CMAKE_MODULE_PATH $ENV{ROCK_CMAKE_MACROS})
include($ENV{ROCK_CMAKE_MACROS}/RockRuby.cmake)
# Install a transformer/runtime file, which will be loaded by orocos.rb whenever
# it loads an oroGen model that has a transformer extension
rock_ruby_library(transformer rock/runtime.rb)

# FIND_PACKAGE(KDL)
# FIND_PACKAGE(OCL)

