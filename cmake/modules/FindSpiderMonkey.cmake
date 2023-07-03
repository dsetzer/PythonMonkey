#
#       CMake Find Mozilla SpiderMonkey JavaScript Engine by Parra Studios
#       CMake script to find Mozilla SpiderMonkey Javascript Engine.
#
#       Copyright (C) 2016 - 2022 Vicente Eduardo Ferrer Garcia <vic798@gmail.com>
#
#       Licensed under the Apache License, Version 2.0 (the "License");
#       you may not use this file except in compliance with the License.
#       You may obtain a copy of the License at
#
#               http://www.apache.org/licenses/LICENSE-2.0
#
#       Unless required by applicable law or agreed to in writing, software
#       distributed under the License is distributed on an "AS IS" BASIS,
#       WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#       See the License for the specific language governing permissions and
#       limitations under the License.
#

# Two modes of operation are supported; this is selected when PythonMokeys' setup.sh is run.
# Setup communicates the mode (and other variables for non-automatic mode) by generating
# SpiderMonkeySetup.cmake.
#
# Automatic Mode (default)
# ------------------------
# Find the SpiderMonkey header files and libraries
# - finds it where the setup.sh script downloads it to
#
# Mozilla-Repo Mode
# -----------------
# - set via setup.sh --with-mozilla=/path/to/hg/mozilla-central
# - expects that the library is already built
# - copies the library over at build time so that it can wind up in the wheel, get proper rpath, etc
# 
#
# SPIDERMONKEY_INCLUDE_DIR     - where to find jsapi.h, etc.
# SPIDERMONKEY_LIBRARY         - List of libraries when using libjs.
# SPIDERMONKEY_FOUND           - True if SpiderMonkey found.
# SPIDERMONKEY_THREADSAFE      - True if SpiderMonkey is compiled with multi threading support.

include(SpiderMonkeySetup)
include(CheckIncludeFileCXX)
include(CheckCXXSourceCompiles)
include(CheckCXXSourceRuns)
include(FindPackageHandleStandardArgs)

# Prevent verbosity if already included
if(SPIDERMONKEY_FOUND)
        set(SPIDERMONKEY_FIND_QUIETLY TRUE)
endif()

message("---------------------------------------------------------------------------------")
if(DEFINED MOZILLA)
  message(" * FindSpiderMonkey - Running in Mozilla-Repo mode")
  message(" . ${MOZILLA} contains SpiderMonkey version ${LIBMOZJS_VERSION}")
  set(SPIDERMONKEY_LIBRARY ${LIBMOZJS})
  set(SPIDERMONKEY_INCLUDE_DIR ${MOZJS_INCLUDE})
  file(COPY ${LIBMOZJS_ORIGIN_PATH} DESTINATION python/pythonmonkey/${LIBMOZJS})
  message("${LIBMOZJS_ORIGIN_PATH} and ${LIBMOZJS}")
else()
  message("FindSpiderMonkey - Running in auto-detect mode")
endif()

set(SPIDERMONKEY_HEADERS jsapi.h js/RequiredDefines.h)
set(SPIDERMONKEY_INCLUDE_SUFFIX_PATHS dist/include js/src include include/js)
set(SPIDERMONKEY_LIB_SUFFIX_PATHS js/src/build lib)

if(NOT DEFINED MOZILLA)
  # SpiderMonkey search paths
  set(SPIDERMONKEY_PATHS
        "${CMAKE_CURRENT_SOURCE_DIR}/_spidermonkey_install"
        "${CMAKE_CURRENT_SOURCE_DIR}/_spidermonkey_install/lib"
        ${SPIDERMONKEY_ROOT}
        $ENV{SPIDERMONKEY_ROOT}
        ~/Library/Frameworks
        /Library/Frameworks
        /usr/local/lib
        /usr/local
        /usr
        /sw # Fink
        /opt/local # DarwinPorts
        /opt/csw # Blastwave
        /opt
        /usr/freeware
        C:/mozilla-source/mozilla-unified/obj-x86_64-pc-mingw32 # Windows Mozilla bootstrap build
  )

  set(SPIDERMONKEY_INCLUDE_SUFFIX_PATHS ${SPIDERMONKEY_INCLUDE_SUFFIX_PATHS} include/mozjs-48a1 include/mozjs-102/)

  # Find SpiderMonkey include path
  find_path(SPIDERMONKEY_INCLUDE_DIR ${SPIDERMONKEY_HEADERS}
    PATHS ${SPIDERMONKEY_PATHS}
    PATH_SUFFIXES ${SPIDERMONKEY_INCLUDE_SUFFIX_PATHS}
    DOC "Mozilla SpiderMonkey JavaScript Engine Headers"
    NO_DEFAULT_PATH
  )

# SpiderMonkey libs
  set(SPIDERMONKEY_LIBRARY_NAMES libmozjs-102.so libmozjs-102.dylib mozjs-102.lib)

  # Find SpiderMonkey base library
  find_library(SPIDERMONKEY_LIBRARY
    NAMES ${SPIDERMONKEY_LIBRARY_NAMES}
    PATHS ${SPIDERMONKEY_PATHS}
    PATH_SUFFIXES ${SPIDERMONKEY_LIB_SUFFIX_PATHS}
    DOC "Mozilla SpiderMonkey JavaScript Engine Library"
  )
endif()
set(SPIDERMONKEY_LIBRARIES ${SPIDERMONKEY_LIBRARY})

list(APPEND CMAKE_REQUIRED_INCLUDES ${SPIDERMONKEY_INCLUDE_DIR})
list(APPEND CMAKE_REQUIRED_DEFINITIONS ${SPIDERMONKEY_DEFINITIONS})
list(APPEND CMAKE_REQUIRED_LIBRARIES ${SPIDERMONKEY_LIBRARY})

check_cxx_source_compiles(
        "#include <jsapi.h>
        int main()
        {
    JSRuntime *rt = JS_NewRuntime(8L * 1024L * 1024L);
                if (rt != NULL)
                {
                return 0;
  }
  return 1;
        }"

        SPIDERMONKEY_BUILDS
)

find_package_handle_standard_args(SpiderMonkey DEFAULT_MSG SPIDERMONKEY_LIBRARIES SPIDERMONKEY_INCLUDE_DIR) # SPIDERMONKEY_BUILDS)

if(SPIDERMONKEY_FOUND)
        set(CMAKE_REQUIRED_INCLUDES ${SPIDERMONKEY_INCLUDE_DIR})
        set(CMAKE_REQUIRED_DEFINITIONS ${SPIDERMONKEY_DEFINITIONS})
        set(CMAKE_REQUIRED_LIBRARIES ${SPIDERMONKEY_LIBRARY})


        find_path(SPIDERMONKEY_JS_CONFIG_HEADER_PATH js-config.h
                PATHS ${SPIDERMONKEY_PATHS}
                PATH_SUFFIXES ${SPIDERMONKEY_INCLUDE_SUFFIX_PATHS}
                DOC "Mozilla SpiderMonkey JavaScript Engine Config Header"
        )

        check_include_file_cxx("${SPIDERMONKEY_JS_CONFIG_HEADER_PATH}/js-config.h" SPIDERMONKEY_JS_CONFIG_HEADER)

        if(NOT SPIDERMONKEY_JS_CONFIG_HEADER)
                check_cxx_source_runs(
                        "#include <stdio.h>
                        extern \"C\" void js_GetCurrentThread();
                        int main()
                        {
                                printf(\"%p\", (void *)js_GetCurrentThread);
                                return ((void *)js_GetCurrentThread != NULL) ? 0 : 1;
                        }"

                        SPIDERMONKEY_THREADSAFE
                )

                if(SPIDERMONKEY_THREADSAFE)
                        set(SPIDERMONKEY_DEFINITIONS ${SPIDERMONKEY_DEFINITIONS} -DJS_THREADSAFE)
                endif()
        else()
                file(STRINGS "${SPIDERMONKEY_JS_CONFIG_HEADER_PATH}/js-config.h" JS_THREADSAFE REGEX "^#define JS_THREADSAFE [^\"]*$")

                if(${JS_THREADSAFE} MATCHES "1")
                        set(SPIDERMONKEY_THREADSAFE "TRUE")
                endif()
        endif()

        # Removed in newest versions of SpiderMonkey
        #if(NOT SPIDERMONKEY_THREADSAFE)
        #       message(FATAL_ERROR "SpiderMonkey must be built with JS_THREADSAFE")
        #endif()

        get_filename_component(SPIDERMONKEY_LIBDIR ${SPIDERMONKEY_LIBRARY} PATH)

        link_directories(${SPIDERMONKEY_LIBDIR})
endif()

list(REMOVE_ITEM CMAKE_REQUIRED_LIBRARIES ${SPIDERMONKEY_LIBRARY})
list(REMOVE_DUPLICATES CMAKE_REQUIRED_LIBRARIES)

mark_as_advanced(SPIDERMONKEY_INCLUDE_DIR SPIDERMONKEY_LIBRARY)
mark_as_advanced(SPIDERMONKEY_JS_CONFIG_HEADER_PATH)
message("---------------------------------------------------------------------------------")
