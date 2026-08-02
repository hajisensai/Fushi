package app.cash.quickjs;

import io.roastedroot.quickjs4j.annotations.Builtins;
import io.roastedroot.quickjs4j.annotations.HostFunction;

import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.Map;

@Builtins("javaApi")
public class JavaApi {
    public final Map<String, Object> boundObjects = new HashMap<>();

    public void bindObject(String name, Object obj) {
        boundObjects.put(name, obj);
    }

    @HostFunction("callBoundMethod")
    public Object callBoundMethod(String objectName, String methodName, Object... args) {
        Object obj = boundObjects.get(objectName);
        if (obj == null) {
            throw new IllegalArgumentException("No object bound with name: " + objectName);
        }

        try {
            Class<?>[] paramTypes = new Class<?>[args.length];
            for (int i = 0; i < args.length; i++) {
                paramTypes[i] = args[i] != null ? args[i].getClass() : Object.class;
            }

            Method method = obj.getClass().getMethod(methodName, paramTypes);
            return method.invoke(obj, args);
        } catch (Exception e) {
            throw new RuntimeException("Error calling method " + methodName + " on " + objectName, e);
        }
    }
}