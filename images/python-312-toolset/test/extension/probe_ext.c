/* A minimal C extension module, compiled in ubi9-python-312-toolset and
 * imported in ubi9-python-312-runtime by images/python-312-toolset/test. */

#define PY_SSIZE_T_CLEAN
#include <Python.h>

static PyObject *where(PyObject *self, PyObject *args)
{
  return PyUnicode_FromString("compiled in the toolset");
}

static PyMethodDef methods[] = {
  {"where", where, METH_NOARGS, "Say where this module was built."},
  {NULL, NULL, 0, NULL},
};

static struct PyModuleDef module = {
  PyModuleDef_HEAD_INIT, "probe_ext", NULL, -1, methods,
};

PyMODINIT_FUNC PyInit_probe_ext(void)
{
  return PyModule_Create(&module);
}
