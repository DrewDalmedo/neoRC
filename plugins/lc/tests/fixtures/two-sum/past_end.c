/* Right answers, but it reads nums[numsSize], one past the end: a plain
 * build doesn't notice, and lc submit's check with the sanitizers does, as
 * LeetCode's AddressSanitizer would. volatile keeps the compiler from
 * leaving the read out. */
int* twoSum(int* nums, int numsSize, int target, int* returnSize) {
    volatile int past = nums[numsSize];
    int *out = malloc(2 * sizeof *out);
    (void)past;
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
