# Copyright (c) 2019, NVIDIA CORPORATION.

# cython: profile=False
# distutils: language = c++
# cython: embedsignature = True
# cython: language_level = 3

from cudf.bindings.cudf_cpp cimport *
from cudf.bindings.cudf_cpp import *
from cudf.utils.cudautils import modulo
from librmm_cffi import librmm as rmm

import numpy as np
import pandas as pd
import pyarrow as pa

from librmm_cffi import librmm as rmm

from libc.stdint cimport uintptr_t
from libc.stdlib cimport calloc, malloc, free

from libcpp.map cimport map as cmap
from libcpp.string  cimport string as cstring


pandas_version = tuple(map(int, pd.__version__.split('.', 2)[:2]))


def clone_columns_with_size(in_cols, row_size):
    from cudf.dataframe import columnops
    out_cols = []
    for col in in_cols:
        o_col = columnops.column_empty_like(col,
                                            dtype=col.dtype,
                                            masked=col.has_null_mask,
                                            newsize=row_size)
        out_cols.append(o_col)

    return out_cols


def apply_gather(in_cols, maps, out_cols=None):
    """
      Call cudf::gather.

     * in_cols input column array
     * maps RMM device array with gdf_index_type (np.int32 compatible dtype)
     * out_cols the destination column array to output

     * returns out_cols
    """
    if in_cols[0].dtype == np.dtype("object"):
        in_size = in_cols[0].data.size()
    else:
        in_size = in_cols[0].data.size

    from cudf.dataframe import columnops
    maps = columnops.as_column(maps).astype("int32")
    maps = maps.data.mem
    # TODO: replace with libcudf pymod when available
    maps = modulo(maps, in_size)

    col_count=len(in_cols)
    gather_count = len(maps)

    cdef gdf_column** c_in_cols = cols_view_from_cols(in_cols)
    cdef cudf_table* c_in_table = new cudf_table(c_in_cols, col_count)

    # check out_cols == in_cols and out_cols=None cases
    cdef bool is_same_input = False
    cdef gdf_column** c_out_cols
    cdef cudf_table* c_out_table
    if out_cols == in_cols:
        is_same_input = True
        c_out_table = c_in_table
    elif out_cols is not None:
        c_out_cols = cols_view_from_cols(out_cols)
        c_out_table = new cudf_table(c_out_cols, col_count)
    else:
        out_cols = clone_columns_with_size(in_cols, gather_count)
        c_out_cols = cols_view_from_cols(out_cols)
        c_out_table = new cudf_table(c_out_cols, col_count)

    cdef uintptr_t c_maps_ptr
    cdef gdf_index_type* c_maps
    if gather_count != 0:
        if out_cols[0].dtype == np.dtype("object"):
            out_size = out_cols[0].data.size()
        else:
            out_size = out_cols[0].data.size
        assert gather_count == out_size

        c_maps_ptr = get_ctype_ptr(maps)
        c_maps = <gdf_index_type*>c_maps_ptr

        with nogil:
            gather(c_in_table, c_maps, c_out_table)

    for i, col in enumerate(out_cols):
        col._update_null_count(c_out_cols[i].null_count)
        if col.dtype == np.dtype("object") and len(col) > 0:
            update_nvstrings_col(
                out_cols[i],
                <uintptr_t>c_out_cols[i].dtype_info.category)

    if is_same_input is False:
        free_table(c_out_table, c_out_cols)

    free_table(c_in_table, c_in_cols)

    return out_cols


def apply_gather_column(in_col, maps, out_col=None):
    """
      Call cudf::gather.

     * in_cols input column
     * maps device array
     * out_cols the destination column to output

     * returns out_col
    """

    in_cols = [in_col]
    out_cols = None if out_col is None else [out_col]

    out_cols = apply_gather(in_cols, maps, out_cols)

    return out_cols[0]


def apply_gather_array(dev_array, maps, out_col=None):
    """
      Call cudf::gather.

     * dev_array input device array
     * maps device array
     * out_cols the destination column to output

     * returns out_col
    """
    from cudf.dataframe import columnops

    in_col = columnops.as_column(dev_array)
    return apply_gather_column(in_col, maps, out_col)


def copy_column(input_col):
    """
        Call cudf::copy
    """
    cdef gdf_column* c_input_col = column_view_from_column(input_col)
    cdef gdf_column* output = <gdf_column*>malloc(sizeof(gdf_column))

    with nogil:
        output[0] = copy(c_input_col[0])

    data, mask = gdf_column_to_column_mem(output)
    from cudf.dataframe.column import Column

    free(c_input_col)
    free(output)

    return Column.from_mem_views(data, mask, output.null_count)
