int* twoSum(int* nums, int numsSize, int target, int* returnSize) {
    int *out = malloc(2 * sizeof *out);
    for (int i = 0; i < numsSize; i++)
        for (int j = i + 1; j < numsSize; j++)
            if (nums[i] + nums[j] == target) {
                out[0] = i;
                out[1] = j;
                *returnSize = 2;
                return out;
            }
    *returnSize = 0;
    return out;
}
