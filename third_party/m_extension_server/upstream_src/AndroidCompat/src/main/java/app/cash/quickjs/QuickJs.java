package app.cash.quickjs;

import io.roastedroot.quickjs4j.core.Engine;
import io.roastedroot.quickjs4j.core.Runner;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.Closeable;
import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;

public final class QuickJs implements Closeable {
    private Runner runner;
    private ObjectMapper mapper;
    private JavaApi javaApi;

    public static QuickJs create() {
        return new QuickJs();
    }

    public QuickJs() {
        this.mapper = new ObjectMapper();
        this.javaApi = new JavaApi();
        
        Engine engine = Engine.builder()
            .addBuiltins(JavaApi_Builtins.toBuiltins(javaApi))
            .build();
        
        this.runner = Runner.builder().withEngine(engine).build();
    }

    public Object evaluate(String script, String ignoredFileName) {
        return this.evaluate(script);
    }

    public Object evaluate(String script) {
        try {
            // Inject bound objects as JS objects with methods
            StringBuilder fullScript = new StringBuilder();
            for (String name : javaApi.boundObjects.keySet()) {
                fullScript.append("var ").append(name).append(" = {\n");
                Object obj = javaApi.boundObjects.get(name);
                Method[] methods = obj.getClass().getMethods();
                for (Method method : methods) {
                    if (method.getDeclaringClass() != Object.class) { // Skip Object methods
                        fullScript.append("  ").append(method.getName()).append(": function(");
                        Class<?>[] params = method.getParameterTypes();
                        for (int i = 0; i < params.length; i++) {
                            if (i > 0) fullScript.append(", ");
                            fullScript.append("arg").append(i);
                        }
                        fullScript.append(") { return javaApi.callBoundMethod('").append(name).append("', '").append(method.getName()).append("'");
                        for (int i = 0; i < params.length; i++) {
                            fullScript.append(", arg").append(i);
                        }
                        fullScript.append("); },\n");
                    }
                }
                fullScript.append("};\n");
            }
            fullScript.append(script);
            
            // Wrap the script to output the result as JSON, handling undefined
            String wrappedScript = "console.log('QuickJs: Starting script execution');\n" +
                "try {\n" +
                "let __result = (" + fullScript.toString() + ");\n" +
                "console.log('QUICJS_RESULT:' + (__result === undefined ? 'null' : JSON.stringify(__result)));\n" +
                "} catch (e) {\n" +
                "console.log('QUICJS_RESULT:{\"error\": \"' + e.message + '\"}');\n" +
                "}";
            try {
                runner.compileAndExec(wrappedScript);
            } catch (Exception e) {
                return translateTypeFromJson("{\"error\": \"JavaScript execution failed: " + e.getMessage() + "\"}");
            }
            
            String output = runner.stdout().trim();
            
            String[] lines = output.split("\n");
            String resultLine = null;
            for (String line : lines) {
                if (line.startsWith("QUICJS_RESULT:")) {
                    resultLine = line.substring(7);
                    break;
                }
            }
            
            if (resultLine == null) {
                throw new QuickJsException("No RESULT marker found in JavaScript output: " + output, null);
            }
            
            if (resultLine.isEmpty()) {
                throw new QuickJsException("Empty result from JavaScript execution", null);
            }
            
            try {
                return translateTypeFromJson(resultLine);
            } catch (Exception e) {
                throw new QuickJsException("JSON parsing error: " + e.getMessage() + " for input: " + resultLine, e);
            }
        } catch (Exception exception) {
            throw new QuickJsException(exception.getMessage(), exception);
        }
    }

    private Object translateTypeFromJson(String json) throws Exception {
        Object value = mapper.readValue(json, Object.class);
        return translateType(value);
    }

    private Object translateType(Object obj) {
        if (obj instanceof Boolean) {
            return obj;
        } else if (obj instanceof Number) {
            Number num = (Number) obj;
            if (num.doubleValue() == num.intValue()) {
                return num.intValue();
            } else {
                return num.doubleValue();
            }
        } else if (obj instanceof String) {
            return obj;
        } else if (obj instanceof java.util.List) {
            java.util.List<?> list = (java.util.List<?>) obj;
            if (list.isEmpty()) {
                return new int[0];
            }
            Object first = list.get(0);
            if (first instanceof Boolean) {
                return list.stream().map(Boolean.class::cast).toArray(Boolean[]::new);
            } else if (first instanceof Number) {
                return list.stream().mapToDouble(o -> ((Number) o).doubleValue()).toArray();
            } else if (first instanceof String) {
                return list.toArray(new String[0]);
            } else {
                return list.toArray();
            }
        }
        return obj;
    }

    public byte[] compile(String sourceCode, String ignoredFileName) {
        return sourceCode.getBytes();
    }

    public Object execute(byte[] bytecode) {
        return this.evaluate(new String(bytecode));
    }

    public <T> void set(String name, Class<T> ignoredType, T object) {
        javaApi.bindObject(name, object);
    }

    @Override
    public void close() {
        if (this.runner != null) {
            this.runner.close();
            this.runner = null;
        }
    }
}
