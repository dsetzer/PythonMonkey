/**
 * @file jsTypeFactory.cc
 * @author Caleb Aikens (caleb@distributive.network)
 * @brief
 * @version 0.1
 * @date 2023-02-15
 *
 * @copyright Copyright (c) 2023
 *
 */

#include "include/jsTypeFactory.hh"

#include "include/modules/pythonmonkey/pythonmonkey.hh"
#include "include/PyType.hh"
#include "include/FuncType.hh"
#include "include/JSFunctionProxy.hh"
#include "include/JSObjectProxy.hh"
#include "include/PyProxyHandler.hh"
#include "include/pyTypeFactory.hh"
#include "include/StrType.hh"
#include "include/IntType.hh"
#include "include/PromiseType.hh"
#include "include/ExceptionType.hh"
#include "include/BufferType.hh"

#include <jsapi.h>
#include <jsfriendapi.h>
#include <js/Proxy.h>

#include <Python.h>

#define HIGH_SURROGATE_START 0xD800
#define LOW_SURROGATE_START 0xDC00
#define LOW_SURROGATE_END 0xDFFF
#define BMP_END 0x10000

struct PythonExternalString : public JSExternalStringCallbacks {
  void finalize(char16_t *chars) const override {}
  size_t sizeOfBuffer(const char16_t *chars, mozilla::MallocSizeOf mallocSizeOf) const override {
    return 0;
  }
};

static constexpr PythonExternalString PythonExternalStringCallbacks;

size_t UCS4ToUTF16(const uint32_t *chars, size_t length, uint16_t **outStr) {
  uint16_t *utf16String = (uint16_t *)malloc(sizeof(uint16_t) * length*2);
  size_t utf16Length = 0;

  for (size_t i = 0; i < length; i++) {
    if (chars[i] < HIGH_SURROGATE_START || (chars[i] > LOW_SURROGATE_END && chars[i] < BMP_END)) {
      utf16String[utf16Length] = uint16_t(chars[i]);
      utf16Length += 1;
    }
    else {
      /* *INDENT-OFF* */
      utf16String[utf16Length]      = uint16_t(((0b1111'1111'1100'0000'0000 & (chars[i] - BMP_END)) >> 10) + HIGH_SURROGATE_START);
      utf16String[utf16Length + 1]  = uint16_t(((0b0000'0000'0011'1111'1111 & (chars[i] - BMP_END)) >> 00) +  LOW_SURROGATE_START);
      utf16Length += 2;
      /* *INDENT-ON* */
    }
  }
  *outStr = utf16String;
  return utf16Length;
}

JS::Value jsTypeFactory(JSContext *cx, PyObject *object) {
  JS::RootedValue returnType(cx);

  if (PyBool_Check(object)) {
    returnType.setBoolean(PyLong_AsLong(object));
  }
  else if (PyLong_Check(object)) {
    if (PyObject_IsInstance(object, PythonMonkey_BigInt)) { // pm.bigint is a subclass of the builtin int type
      JS::BigInt *bigint = IntType(object).toJsBigInt(cx);
      returnType.setBigInt(bigint);
    } else if (_PyLong_NumBits(object) <= 53) { // num <= JS Number.MAX_SAFE_INTEGER, the mantissa of a float64 is 53 bits (with 52 explicitly stored and the highest bit always being 1)
      int64_t num = PyLong_AsLongLong(object);
      returnType.setNumber(num);
    } else {
      PyErr_SetString(PyExc_OverflowError, "Absolute value of the integer exceeds JS Number.MAX_SAFE_INTEGER. Use pythonmonkey.bigint instead.");
    }
  }
  else if (PyFloat_Check(object)) {
    returnType.setNumber(PyFloat_AsDouble(object));
  }
  else if (PyUnicode_Check(object)) {
    switch (PyUnicode_KIND(object)) {
    case (PyUnicode_4BYTE_KIND): {
        uint32_t *u32Chars = PyUnicode_4BYTE_DATA(object);
        uint16_t *u16Chars;
        size_t u16Length = UCS4ToUTF16(u32Chars, PyUnicode_GET_LENGTH(object), &u16Chars);
        JSString *str = JS_NewUCStringCopyN(cx, (char16_t *)u16Chars, u16Length);
        free(u16Chars);
        returnType.setString(str);
        break;
      }
    case (PyUnicode_2BYTE_KIND): {
        JSString *str = JS_NewExternalString(cx, (char16_t *)PyUnicode_2BYTE_DATA(object), PyUnicode_GET_LENGTH(object), &PythonExternalStringCallbacks);
        returnType.setString(str);
        break;
      }
    case (PyUnicode_1BYTE_KIND): {

        JSString *str = JS_NewExternalString(cx, (char16_t *)PyUnicode_1BYTE_DATA(object), PyUnicode_GET_LENGTH(object), &PythonExternalStringCallbacks);
        /* TODO (Caleb Aikens): this is a hack to set the JSString::LATIN1_CHARS_BIT, because there isnt an API for latin1 JSExternalStrings.
         * Ideally we submit a patch to Spidermonkey to make this part of their API with the following signature:
         * JS_NewExternalString(JSContext *cx, const char *chars, size_t length, const JSExternalStringCallbacks *callbacks)
         */
        // FIXME: JSExternalString are all treated as two-byte strings when GCed
        //    see https://hg.mozilla.org/releases/mozilla-esr102/file/tip/js/src/vm/StringType-inl.h#l514
        //        https://hg.mozilla.org/releases/mozilla-esr102/file/tip/js/src/vm/StringType.h#l1808
        *(std::atomic<unsigned long> *)str |= 512;
        returnType.setString(str);
        break;
      }
    }
    memoizePyTypeAndGCThing(new StrType(object), returnType);
  }
  else if (PyObject_TypeCheck(object, &JSFunctionProxyType)) {
    returnType.setObject(**((JSFunctionProxy *)object)->jsFunction);
  }
  else if (PyFunction_Check(object) || PyCFunction_Check(object)) {
    JS::RootedValue v(cx, JS::ObjectValue(*JS_GetFunctionObject(JS_NewFunction(cx, nullptr, 0, 0, NULL))));
    JSObject *proxy;
    JS::RootedObject proto(cx);
    JS_GetClassPrototype(cx, JSProtoKey::JSProto_Function, &proto);
    proxy = js::NewProxyObject(cx, new PyFuncProxyHandler(object), v, proto);
    returnType.setObject(*proxy);
    memoizePyTypeAndGCThing(new FuncType(object), returnType);
    Py_INCREF(object); // otherwise the python function object would be double-freed on GC in Python 3.11+
  }
  else if (PyExceptionInstance_Check(object)) {
    JSObject *error = ExceptionType(object).toJsError(cx);
    returnType.setObject(*error);
  }
  else if (PyObject_CheckBuffer(object)) {
    BufferType *pmBuffer = new BufferType(object);
    JSObject *typedArray = pmBuffer->toJsTypedArray(cx); // may return null
    returnType.setObjectOrNull(typedArray);
    memoizePyTypeAndGCThing(pmBuffer, returnType);
  }
  else if (PyObject_TypeCheck(object, &JSObjectProxyType)) {
    returnType.setObject(**((JSObjectProxy *)object)->jsObject);
  }
  else if (PyDict_Check(object) || PyList_Check(object)) {
    JS::RootedValue v(cx);
    JSObject *proxy;
    if (PyList_Check(object)) {
      proxy = js::NewProxyObject(cx, new PyListProxyHandler(object), v, NULL);
    } else {
      proxy = js::NewProxyObject(cx, new PyDictProxyHandler(object), v, NULL);
    }
    returnType.setObject(*proxy);
  }
  else if (object == Py_None) {
    returnType.setUndefined();
  }
  else if (object == PythonMonkey_Null) {
    returnType.setNull();
  }
  else if (PythonAwaitable_Check(object)) {
    PromiseType *p = new PromiseType(object);
    JSObject *promise = p->toJsPromise(cx); // may return null
    returnType.setObjectOrNull(promise);
    // nested awaitables would have already been GCed if finished
    // memoizePyTypeAndGCThing(p, returnType);
  }
  else {
    std::string errorString("pythonmonkey cannot yet convert python objects of type: ");
    errorString += Py_TYPE(object)->tp_name;
    PyErr_SetString(PyExc_TypeError, errorString.c_str());
  }
  return returnType;

}

JS::Value jsTypeFactorySafe(JSContext *cx, PyObject *object) {
  JS::Value v = jsTypeFactory(cx, object);
  if (PyErr_Occurred()) {
    // Convert the Python error to a warning
    PyObject *type, *value, *traceback;
    PyErr_Fetch(&type, &value, &traceback); // also clears Python's error stack
    PyObject *msg = PyObject_Str(value);
    PyErr_WarnEx(PyExc_RuntimeWarning, PyUnicode_AsUTF8(msg), 1);
    Py_DECREF(msg);
    Py_XDECREF(type); Py_XDECREF(value); Py_XDECREF(traceback);
    // Return JS `null` on error
    v.setNull();
  }
  return v;
}