import onnx

from ..quant_utils import TENSOR_NAME_QUANT_SUFFIX, QuantizedValue, QuantizedValueType, attribute_to_kwarg
from .base_operator import QuantOperatorBase
from .qdq_base_operator import QDQOperatorBase


class QWhere(QuantOperatorBase):
    def quantize(self):
        node = self.node
        (
            quantized_input_names,
            zero_point_name,
            scale_name,
            nodes,
        ) = self.quantizer.quantize_inputs(node, [0])
        if quantized_input_names is None:
            return super().quantize()
        quantized_output_name = node.output[0] + TENSOR_NAME_QUANT_SUFFIX
        q_output = QuantizedValue(
            node.output[0],
            quantized_output_name,
            scale_name,
            zero_point_name,
            QuantizedValueType.Input,
        )
        self.quantizer.quantized_value_map[node.output[0]] = q_output
        quantized_node_name = ""
        if node.name != "":
            quantized_node_name = node.name + "_quant"

        kwargs = {}
        for attribute in node.attribute:
            kwargs.update(attribute_to_kwarg(attribute))

        quantized_input_names = quantized_input_names.extend(node.input[1:])
        quantized_node = onnx.helper.make_node(
            node.op_type, quantized_input_names, quantized_output_name, quantized_node_name, **kwargs
        )

        nodes.append(quantized_node)
        self.quantizer.new_nodes += nodes


class QDQWhere(QDQOperatorBase):
    def quantize(self):
        node = self.node
        assert node.op_type == "Where"
        if not self.quantizer.is_tensor_quantized(node.input[1]):
            self.quantizer.quantize_tensor(node.input[1])
        if not self.quantizer.is_tensor_quantized(node.input[2]):
            self.quantizer.quantize_tensor(node.input[2])
        if not self.disable_qdq_for_node_output:
            for output in node.output:
                self.quantizer.quantize_tensor(output, node.input[1])
